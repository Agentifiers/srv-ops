package provider

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"
)

func TestMapStatus(t *testing.T) {
	tests := map[string]commonParams.InstanceStatus{
		"ready":            commonParams.InstanceRunning,
		"stopped":          commonParams.InstanceStopped,
		"stopping":         commonParams.InstanceStopped,
		"failed":           commonParams.InstanceError,
		"provisioning":     commonParams.InstanceStatusUnknown,
		"awaiting-tailnet": commonParams.InstanceStatusUnknown,
		"deleting":         commonParams.InstanceStatusUnknown,
		"something-new":    commonParams.InstanceStatusUnknown,
	}
	for state, want := range tests {
		if got := MapStatus(state); got != want {
			t.Errorf("MapStatus(%q) = %q, want %q", state, got, want)
		}
		// GARM v0.2.1 ValidateResult only accepts these four.
		switch MapStatus(state) {
		case commonParams.InstanceRunning, commonParams.InstanceStopped,
			commonParams.InstanceError, commonParams.InstanceStatusUnknown:
		default:
			t.Errorf("MapStatus(%q) is not a status GARM accepts from providers", state)
		}
	}
}

// fakeSrv emulates `ssh srv ...` and guest Tailscale SSH for tests.
type fakeSrv struct {
	mu        sync.Mutex
	instances map[string]SrvInstance
	calls     [][]string
	// newState is the state an instance has right after `srv new`.
	newState string
	// failNew makes `srv new` create a failed VM and exit non-zero.
	failNew bool
	// guestDown makes guest ssh fail.
	guestDown bool
	installs  map[string][]byte
}

func newFakeSrv() *fakeSrv {
	return &fakeSrv{instances: map[string]SrvInstance{}, newState: srvStateReady, installs: map[string][]byte{}}
}

func cmdErr(args []string, stderr string) error {
	return &CommandError{Args: args, Stderr: stderr, Err: errors.New("exit status 1")}
}

func (f *fakeSrv) run(_ context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string{name}, args...))
	if name != "ssh" {
		return nil, fmt.Errorf("unexpected binary %s", name)
	}
	if i := slices.Index(args, "--"); i >= 0 && args[i-1] == "srv" {
		return f.srvCmd(args[i+1:])
	}
	host := args[len(args)-2]
	id := strings.TrimPrefix(host, "root@")
	if f.guestDown {
		return nil, cmdErr(args, "connection refused")
	}
	if _, ok := f.instances[id]; !ok {
		return nil, cmdErr(args, "no such host")
	}
	if remote := args[len(args)-1]; remote != "true" {
		if !strings.Contains(remote, "systemd-run --unit=garm-runner-install --collect bash /run/garm/runner-install.sh") {
			return nil, fmt.Errorf("unexpected guest command %q", remote)
		}
		f.installs[id] = stdin
	}
	return nil, nil
}

func (f *fakeSrv) srvCmd(args []string) ([]byte, error) {
	missing := func(cmd, name string) error {
		return cmdErr(args, fmt.Sprintf("%s %s: instance %q does not exist\n", cmd, name, name))
	}
	switch {
	case len(args) == 2 && args[0] == "--json" && args[1] == "list":
		var parts []string
		for _, inst := range f.instances {
			parts = append(parts, fmt.Sprintf(`{"name":%q,"state":%q,"tailscale_ip":%q}`, inst.Name, inst.State, inst.TailscaleIP))
		}
		return []byte(`{"instances":[` + strings.Join(parts, ",") + `]}`), nil
	case len(args) == 3 && args[0] == "--json" && args[1] == "inspect":
		inst, ok := f.instances[args[2]]
		if !ok {
			return nil, missing("inspect", args[2])
		}
		return fmt.Appendf(nil, `{"instance":{"name":%q,"image":%q,"state":%q,"tailscale_ip":%q,"last_error":%q},"events":[]}`,
			inst.Name, inst.Image, inst.State, inst.TailscaleIP, inst.LastError), nil
	case args[0] == "new":
		name := args[1]
		if _, ok := f.instances[name]; ok {
			return nil, cmdErr(args, "already exists")
		}
		inst := SrvInstance{Name: name, Image: args[3], State: f.newState, TailscaleIP: "100.64.0.9"}
		if f.failNew {
			inst.State, inst.LastError = srvStateFailed, "boom"
			f.instances[name] = inst
			return nil, cmdErr(args, "new failed")
		}
		f.instances[name] = inst
		return nil, nil
	case len(args) == 2 && args[0] == "delete":
		if _, ok := f.instances[args[1]]; !ok {
			return nil, missing("delete", args[1])
		}
		delete(f.instances, args[1])
		return nil, nil
	case len(args) == 2 && (args[0] == "start" || args[0] == "stop"):
		inst, ok := f.instances[args[1]]
		if !ok {
			return nil, missing(args[0], args[1])
		}
		inst.State = map[string]string{"start": srvStateReady, "stop": srvStateStopped}[args[0]]
		f.instances[args[1]] = inst
		return nil, nil
	}
	return nil, fmt.Errorf("unexpected srv command %v", args)
}

func (f *fakeSrv) called(prefix ...string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if i := slices.Index(c, "--"); i >= 0 && len(c[i+1:]) >= len(prefix) && slices.Equal(c[i+1:i+1+len(prefix)], prefix) {
			return true
		}
	}
	return false
}

func TestSrvInspectAndNotFound(t *testing.T) {
	f := newFakeSrv()
	f.instances["gha-1"] = SrvInstance{Name: "gha-1", State: "ready", TailscaleIP: "100.64.0.1"}
	s := NewSrv("srv", f.run)
	inst, err := s.Inspect(context.Background(), "gha-1")
	if err != nil || inst.State != "ready" || inst.TailscaleIP != "100.64.0.1" {
		t.Fatalf("Inspect = %+v, %v", inst, err)
	}
	if _, err := s.Inspect(context.Background(), "gha-2"); !errors.Is(err, errSrvNotFound) {
		t.Fatalf("Inspect missing = %v", err)
	}
	if err := s.Delete(context.Background(), "gha-2"); !errors.Is(err, errSrvNotFound) {
		t.Fatalf("Delete missing = %v", err)
	}
	// Other failures are not mistaken for not-found.
	other := NewSrv("srv", func(context.Context, []byte, string, ...string) ([]byte, error) {
		return nil, cmdErr(nil, "ssh: connect to host srv port 22: Connection refused")
	})
	if _, err := other.Inspect(context.Background(), "gha-1"); err == nil || errors.Is(err, errSrvNotFound) {
		t.Fatalf("Inspect on ssh failure = %v", err)
	}
}
