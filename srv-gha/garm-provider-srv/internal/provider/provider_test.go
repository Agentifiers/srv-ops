package provider

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	commonParams "github.com/cloudbase/garm-provider-common/params"
)

func testProvider(t *testing.T, f *fakeSrv) *Provider {
	t.Helper()
	cfg := &Config{
		SrvHost:      "srv",
		DefaultImage: "gha-runner",
		StateDir:     t.TempDir(),
		ReadyTimeout: Duration{2 * time.Second},
	}
	p := NewProvider(cfg, "ctrl", f.run)
	p.pollWait = 10 * time.Millisecond
	return p
}

func bootstrap(name string) commonParams.BootstrapInstance {
	return commonParams.BootstrapInstance{
		Name: name,
		Tools: []commonParams.RunnerApplicationDownload{
			{OS: new("osx"), Architecture: new("x64"), DownloadURL: new("https://example.invalid/osx.tgz"), Filename: new("osx.tgz")},
			{OS: new("linux"), Architecture: new("x64"), DownloadURL: new("https://example.invalid/linux-x64.tgz"), Filename: new("actions-runner-linux-x64-2.338.1.tar.gz")},
		},
		RepoURL:          "https://github.com/example-org",
		CallbackURL:      "http://100.64.0.10:9997/api/v1/callbacks",
		MetadataURL:      "http://100.64.0.10:9997/api/v1/metadata",
		InstanceToken:    "secret-token",
		OSArch:           commonParams.Amd64,
		OSType:           commonParams.Linux,
		Flavor:           "8c-16g-60g",
		PoolID:           "pool1",
		JitConfigEnabled: true,
		ExtraSpecs:       []byte("{}"),
	}
}

func TestCreateInstance(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	inst, err := p.CreateInstance(context.Background(), bootstrap("garm-ny9HeeQYw2rl"))
	if err != nil {
		t.Fatal(err)
	}
	id := "gha-4545a1e3d9f543fb"
	if inst.ProviderID != id || inst.Name != "garm-ny9HeeQYw2rl" || inst.Status != commonParams.InstanceRunning ||
		inst.OSType != commonParams.Linux || inst.OSName != "arch" || inst.OSArch != commonParams.Amd64 {
		t.Fatalf("instance = %+v", inst)
	}
	if len(inst.Addresses) != 1 || inst.Addresses[0].Address != "100.64.0.9" {
		t.Fatalf("addresses = %+v", inst.Addresses)
	}
	if !f.called("new", id, "--image", "gha-runner", "--cpus", "8", "--ram", "16G", "--rootfs-size", "60G") {
		t.Fatalf("srv new not called as expected: %v", f.calls)
	}
	script := string(f.installs[id])
	if !strings.Contains(script, "actions-runner-linux-x64-2.338.1.tar.gz") || !strings.Contains(script, "secret-token") {
		t.Fatalf("install script lacks linux tools or token:\n%s", script)
	}
	rec, err := p.store.Get(id)
	if err != nil || rec.Name != "garm-ny9HeeQYw2rl" || rec.PoolID != "pool1" || rec.ControllerID != "ctrl" {
		t.Fatalf("record = %+v, %v", rec, err)
	}
	// The secret must not reach the command line.
	for _, c := range f.calls {
		if strings.Contains(strings.Join(c, " "), "secret-token") {
			t.Fatalf("token leaked into argv: %v", c)
		}
	}

	if _, err := p.CreateInstance(context.Background(), bootstrap("garm-ny9HeeQYw2rl")); !errors.Is(err, garmErrors.ErrDuplicateEntity) {
		t.Fatalf("duplicate create = %v", err)
	}
}

func TestCreateInstanceRejectsBadInputBeforeSrv(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	for name, mutate := range map[string]func(*commonParams.BootstrapInstance){
		"flavor":     func(b *commonParams.BootstrapInstance) { b.Flavor = "large" },
		"image":      func(b *commonParams.BootstrapInstance) { b.Image = "Bad_Image" },
		"arch":       func(b *commonParams.BootstrapInstance) { b.OSArch = commonParams.Arm64 },
		"os":         func(b *commonParams.BootstrapInstance) { b.OSType = commonParams.Windows },
		"tools":      func(b *commonParams.BootstrapInstance) { b.Tools = b.Tools[:1] },
		"extraspecs": func(b *commonParams.BootstrapInstance) { b.ExtraSpecs = []byte(`{"pre_install_scripts":{}}`) },
	} {
		bp := bootstrap("garm-" + name)
		mutate(&bp)
		if _, err := p.CreateInstance(context.Background(), bp); err == nil {
			t.Errorf("%s: CreateInstance accepted bad input", name)
		}
	}
	if len(f.calls) != 0 {
		t.Fatalf("srv was called: %v", f.calls)
	}
}

func TestCreateInstanceFailureCleansUp(t *testing.T) {
	for name, setup := range map[string]func(*fakeSrv){
		"new fails":    func(f *fakeSrv) { f.failNew = true },
		"never ready":  func(f *fakeSrv) { f.newState = srvStateProvisioning },
		"vm failed":    func(f *fakeSrv) { f.newState = srvStateFailed },
		"guest no ssh": func(f *fakeSrv) { f.guestDown = true },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeSrv()
			setup(f)
			p := testProvider(t, f)
			p.cfg.ReadyTimeout = Duration{100 * time.Millisecond}
			_, err := p.CreateInstance(context.Background(), bootstrap("garm-fail"))
			var ce *CreateError
			if !errors.As(err, &ce) {
				t.Fatalf("err = %v, want *CreateError", err)
			}
			if ce.Instance.Status != commonParams.InstanceError || len(ce.Instance.ProviderFault) == 0 || ce.Instance.Name != "garm-fail" {
				t.Fatalf("error instance = %+v", ce.Instance)
			}
			id := ProviderID("garm-fail")
			if _, ok := f.instances[id]; ok {
				t.Fatal("VM not deleted")
			}
			if _, err := p.store.Get(id); !errors.Is(err, errRecordNotFound) {
				t.Fatalf("record not removed: %v", err)
			}
		})
	}
}

func TestDeleteInstance(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	if _, err := p.CreateInstance(context.Background(), bootstrap("garm-Del")); err != nil {
		t.Fatal(err)
	}
	id := ProviderID("garm-Del")
	// GARM may pass the runner name instead of the provider ID.
	if err := p.DeleteInstance(context.Background(), "garm-Del"); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.instances[id]; ok {
		t.Fatal("VM not deleted")
	}
	if _, err := p.store.Get(id); !errors.Is(err, errRecordNotFound) {
		t.Fatalf("record = %v", err)
	}
	// Missing everywhere: no-op.
	if err := p.DeleteInstance(context.Background(), id); err != nil {
		t.Fatalf("delete missing = %v", err)
	}
}

func TestGetInstance(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	if _, err := p.CreateInstance(context.Background(), bootstrap("garm-Get")); err != nil {
		t.Fatal(err)
	}
	id := ProviderID("garm-Get")
	for _, ref := range []string{id, "garm-Get"} {
		inst, err := p.GetInstance(context.Background(), ref)
		if err != nil || inst.Name != "garm-Get" || inst.ProviderID != id || inst.Status != commonParams.InstanceRunning {
			t.Fatalf("GetInstance(%s) = %+v, %v", ref, inst, err)
		}
	}
	if _, err := p.GetInstance(context.Background(), "garm-missing"); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("GetInstance missing = %v", err)
	}
}

func TestListInstancesFiltersAndPrunes(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	for _, n := range []string{"garm-a", "garm-b"} {
		if _, err := p.CreateInstance(context.Background(), bootstrap(n)); err != nil {
			t.Fatal(err)
		}
	}
	other := bootstrap("garm-c")
	other.PoolID = "pool2"
	if _, err := p.CreateInstance(context.Background(), other); err != nil {
		t.Fatal(err)
	}
	// Another controller's record is invisible.
	foreign := testRecord("garm-foreign", "pool1")
	foreign.ControllerID = "other-ctrl"
	l, _ := p.store.Lock(context.Background(), foreign.ProviderID)
	p.store.Put(foreign)
	l.Unlock()
	f.instances[foreign.ProviderID] = SrvInstance{Name: foreign.ProviderID, State: srvStateReady}

	// garm-b vanished from srv; garm-a is stopped.
	delete(f.instances, ProviderID("garm-b"))
	a := f.instances[ProviderID("garm-a")]
	a.State = srvStateStopped
	f.instances[a.Name] = a

	// A record whose create is still in flight (lock held) is not pruned.
	inflight := testRecord("garm-inflight", "pool1")
	inflight.ControllerID = "ctrl"
	il, _ := p.store.Lock(context.Background(), inflight.ProviderID)
	p.store.Put(inflight)

	got, err := p.ListInstances(context.Background(), "pool1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "garm-a" || got[0].Status != commonParams.InstanceStopped {
		t.Fatalf("ListInstances = %+v", got)
	}
	if _, err := p.store.Get(ProviderID("garm-b")); !errors.Is(err, errRecordNotFound) {
		t.Fatalf("stale record not pruned: %v", err)
	}
	if _, err := p.store.Get(inflight.ProviderID); err != nil {
		t.Fatalf("in-flight record pruned: %v", err)
	}
	il.Unlock()

	empty, err := p.ListInstances(context.Background(), "no-such-pool")
	if err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty list = %#v, %v", empty, err)
	}
}

func TestRemoveAllInstances(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	for _, n := range []string{"garm-1", "garm-2"} {
		if _, err := p.CreateInstance(context.Background(), bootstrap(n)); err != nil {
			t.Fatal(err)
		}
	}
	f.instances["orb-keepme"] = SrvInstance{Name: "orb-keepme", State: srvStateReady}
	if err := p.RemoveAllInstances(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.instances) != 1 {
		t.Fatalf("instances left = %v", f.instances)
	}
	if recs, _ := p.store.List(); len(recs) != 0 {
		t.Fatalf("records left = %v", recs)
	}
}

func TestStartStop(t *testing.T) {
	f := newFakeSrv()
	p := testProvider(t, f)
	if _, err := p.CreateInstance(context.Background(), bootstrap("garm-ss")); err != nil {
		t.Fatal(err)
	}
	id := ProviderID("garm-ss")
	if err := p.Stop(context.Background(), id, true); err != nil || f.instances[id].State != srvStateStopped {
		t.Fatalf("Stop = %v, state %s", err, f.instances[id].State)
	}
	if err := p.Stop(context.Background(), id, true); err != nil {
		t.Fatalf("Stop again = %v", err)
	}
	if err := p.Start(context.Background(), id); err != nil || f.instances[id].State != srvStateReady {
		t.Fatalf("Start = %v, state %s", err, f.instances[id].State)
	}
	if err := p.Start(context.Background(), "garm-nope"); !errors.Is(err, garmErrors.ErrNotFound) {
		t.Fatalf("Start missing = %v", err)
	}
}

func TestValidatePoolInfo(t *testing.T) {
	p := testProvider(t, newFakeSrv())
	ctx := context.Background()
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	if err := p.ValidatePoolInfo(ctx, "gha-runner", "8c-16g-60g", "", b64(`{"extra_context":{"a":"b"}}`)); err != nil {
		t.Fatal(err)
	}
	if err := p.ValidatePoolInfo(ctx, "", "", "", b64("null")); err != nil {
		t.Fatal(err)
	}
	if err := p.ValidatePoolInfo(ctx, "", "8c", "", ""); err == nil {
		t.Fatal("bad flavor accepted")
	}
	if err := p.ValidatePoolInfo(ctx, "", "", "", b64(`{"bogus":1}`)); err == nil {
		t.Fatal("unknown extra spec accepted")
	}
}
