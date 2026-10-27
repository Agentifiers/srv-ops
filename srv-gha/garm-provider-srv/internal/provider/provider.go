package provider

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/cloudbase/garm-provider-common/cloudconfig"
	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	execCommon "github.com/cloudbase/garm-provider-common/execution/common"
	executionv011 "github.com/cloudbase/garm-provider-common/execution/v0.1.1"
	commonParams "github.com/cloudbase/garm-provider-common/params"
	commonUtil "github.com/cloudbase/garm-provider-common/util"
)

// Version is reported by GetVersion.
var Version = "v0.1.0"

const (
	osName          = "arch"
	installUnit     = "garm-runner-install"
	installScript   = "/run/garm/runner-install.sh"
	cleanupTimeout  = 2 * time.Minute
	defaultPollWait = 2 * time.Second
)

var _ executionv011.ExternalProvider = (*Provider)(nil)

// Provider implements the GARM external provider interface (v0.1.0 and
// v0.1.1) on top of srv.
type Provider struct {
	cfg          *Config
	controllerID string
	store        *Store
	srv          *Srv
	run          Runner
	pollWait     time.Duration
	now          func() time.Time
}

// NewProvider wires a provider. run executes ssh; pass ExecRunner outside tests.
func NewProvider(cfg *Config, controllerID string, run Runner) *Provider {
	return &Provider{
		cfg:          cfg,
		controllerID: controllerID,
		store:        NewStore(cfg.StateDir),
		srv:          NewSrv(cfg.SrvHost, run),
		run:          run,
		pollWait:     defaultPollWait,
		now:          time.Now,
	}
}

// CreateError is returned when CreateInstance fails after the VM may have
// been created. Instance carries status=error and the fault for GARM.
type CreateError struct {
	Instance commonParams.ProviderInstance
	Err      error
}

func (e *CreateError) Error() string { return e.Err.Error() }
func (e *CreateError) Unwrap() error { return e.Err }

// extraSpecs is the pool extra_specs this provider understands; both fields
// feed cloudconfig.GetRunnerInstallScript.
type extraSpecs struct {
	RunnerInstallTemplate []byte            `json:"runner_install_template,omitempty"`
	ExtraContext          map[string]string `json:"extra_context,omitempty"`
}

func parseExtraSpecs(raw []byte) error {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var specs extraSpecs
	if err := dec.Decode(&specs); err != nil {
		return fmt.Errorf("invalid extra_specs: %w", err)
	}
	return nil
}

func (p *Provider) imageFor(image string) (string, error) {
	if image == "" {
		image = p.cfg.DefaultImage
	}
	return image, ValidateImageName(image)
}

func (p *Provider) CreateInstance(ctx context.Context, bp commonParams.BootstrapInstance) (commonParams.ProviderInstance, error) {
	// Everything that can be checked without a VM is checked first, so bad
	// pool settings never leave anything behind.
	if bp.OSType != "" && bp.OSType != commonParams.Linux {
		return commonParams.ProviderInstance{}, fmt.Errorf("unsupported os_type %q: srv images are linux", bp.OSType)
	}
	if bp.OSArch != "" && bp.OSArch != commonParams.Amd64 {
		return commonParams.ProviderInstance{}, fmt.Errorf("unsupported arch %q: srv runs amd64 guests", bp.OSArch)
	}
	flavor, err := ParseFlavor(bp.Flavor)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	image, err := p.imageFor(bp.Image)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	if err := parseExtraSpecs(bp.ExtraSpecs); err != nil {
		return commonParams.ProviderInstance{}, err
	}
	tools, err := commonUtil.GetTools(commonParams.Linux, commonParams.Amd64, bp.Tools)
	if err != nil {
		return commonParams.ProviderInstance{}, fmt.Errorf("selecting runner tools: %w", err)
	}
	script, err := cloudconfig.GetRunnerInstallScript(bp, tools, bp.Name)
	if err != nil {
		return commonParams.ProviderInstance{}, fmt.Errorf("generating runner install script: %w", err)
	}

	id := ProviderID(bp.Name)
	lock, err := p.store.Lock(ctx, id)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	keepLock := true
	defer func() {
		if keepLock {
			lock.Unlock()
		} else {
			lock.UnlockAndRemove()
		}
	}()

	if _, err := p.store.Get(id); err == nil {
		switch _, err := p.srv.Inspect(ctx, id); {
		case err == nil:
			return commonParams.ProviderInstance{}, fmt.Errorf("instance %s (%s): %w", bp.Name, id, garmErrors.ErrDuplicateEntity)
		case !errors.Is(err, errSrvNotFound):
			return commonParams.ProviderInstance{}, fmt.Errorf("checking for existing instance: %w", err)
		}
		// Stale record from an earlier failed attempt: overwrite it.
	} else if !errors.Is(err, errRecordNotFound) {
		return commonParams.ProviderInstance{}, err
	}

	rec := Record{
		Name:         bp.Name,
		ProviderID:   id,
		PoolID:       bp.PoolID,
		ControllerID: p.controllerID,
		Image:        image,
		Flavor:       flavor.String(),
		CreatedAt:    p.now().UTC(),
	}
	if err := p.store.Put(rec); err != nil {
		return commonParams.ProviderInstance{}, err
	}

	inst, err := p.provision(ctx, id, image, flavor, script)
	if err != nil {
		cleanupErr := p.cleanupFailedCreate(ctx, id)
		if cleanupErr == nil {
			keepLock = false
		}
		fault := err
		if cleanupErr != nil {
			fault = fmt.Errorf("%w; cleanup failed (record kept): %v", err, cleanupErr)
		}
		return commonParams.ProviderInstance{}, &CreateError{
			Instance: commonParams.ProviderInstance{
				ProviderID:    id,
				Name:          bp.Name,
				OSType:        commonParams.Linux,
				OSName:        osName,
				OSArch:        commonParams.Amd64,
				Status:        commonParams.InstanceError,
				ProviderFault: []byte(fault.Error()),
			},
			Err: fault,
		}
	}
	ret := toProviderInstance(rec.Name, inst)
	ret.Status = commonParams.InstanceRunning
	return ret, nil
}

// provision runs srv new and bootstraps the runner. Any error means the VM
// must be torn down.
func (p *Provider) provision(ctx context.Context, id, image string, flavor Flavor, script []byte) (SrvInstance, error) {
	if err := p.srv.New(ctx, id, image, flavor); err != nil {
		return SrvInstance{}, fmt.Errorf("srv new: %w", err)
	}
	inst, err := p.waitReady(ctx, id)
	if err != nil {
		return SrvInstance{}, err
	}
	if err := p.waitGuestSSH(ctx, id); err != nil {
		return SrvInstance{}, err
	}
	if err := p.startInstall(ctx, id, script); err != nil {
		return SrvInstance{}, err
	}
	return inst, nil
}

func (p *Provider) cleanupFailedCreate(ctx context.Context, id string) error {
	// ctx may already be cancelled (GARM shutting down); cleanup still runs.
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
	defer cancel()
	if err := p.srv.Delete(cctx, id); err != nil && !errors.Is(err, errSrvNotFound) {
		return fmt.Errorf("srv delete %s: %w", id, err)
	}
	return p.store.Delete(id)
}

func (p *Provider) sleep(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(p.pollWait):
		return nil
	}
}

func (p *Provider) waitReady(ctx context.Context, id string) (SrvInstance, error) {
	ctx, cancel := context.WithTimeout(ctx, p.cfg.ReadyTimeout.Duration)
	defer cancel()
	last := "unknown"
	for {
		inst, err := p.srv.Inspect(ctx, id)
		switch {
		case errors.Is(err, errSrvNotFound):
			return SrvInstance{}, fmt.Errorf("instance %s disappeared while waiting for ready", id)
		case err != nil:
			// Transient ssh/srv failures are retried until the deadline.
			last = err.Error()
		case inst.State == srvStateReady:
			return inst, nil
		case inst.State == srvStateFailed || inst.State == srvStateDeleting || inst.State == srvStateDeleted:
			return SrvInstance{}, fmt.Errorf("instance %s is %s: %s (see: ssh %s logs %s serial)", id, inst.State, inst.LastError, p.cfg.SrvHost, id)
		default:
			last = "state " + inst.State
		}
		if err := p.sleep(ctx); err != nil {
			return SrvInstance{}, fmt.Errorf("timed out after %s waiting for %s to become ready (last: %s)", p.cfg.ReadyTimeout, id, last)
		}
	}
}

func guestSSHArgs(id string, command string) []string {
	return []string{
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=5",
		"root@" + id,
		command,
	}
}

func (p *Provider) waitGuestSSH(ctx context.Context, id string) error {
	ctx, cancel := context.WithTimeout(ctx, p.cfg.ReadyTimeout.Duration)
	defer cancel()
	var last error
	for {
		_, err := p.run(ctx, nil, "ssh", guestSSHArgs(id, "true")...)
		if err == nil {
			return nil
		}
		last = err
		if err := p.sleep(ctx); err != nil {
			return fmt.Errorf("timed out after %s waiting for Tailscale SSH on %s: %v", p.cfg.ReadyTimeout, id, last)
		}
	}
}

// installCommand stores the script (it embeds the instance callback token)
// in a root-only file on tmpfs and runs it as a transient unit, so dropping
// the ssh session cannot kill the installer.
const installCommand = `set -eu
umask 077
install -d -m 0700 /run/garm
cat > ` + installScript + `
systemctl reset-failed ` + installUnit + `.service 2>/dev/null || true
systemd-run --unit=` + installUnit + ` --collect bash ` + installScript

func (p *Provider) startInstall(ctx context.Context, id string, script []byte) error {
	remote := "bash -c " + shellQuote(installCommand)
	if _, err := p.run(ctx, script, "ssh", guestSSHArgs(id, remote)...); err != nil {
		return fmt.Errorf("starting runner install on %s: %w", id, err)
	}
	return nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func toProviderInstance(name string, inst SrvInstance) commonParams.ProviderInstance {
	ret := commonParams.ProviderInstance{
		ProviderID: inst.Name,
		Name:       name,
		OSType:     commonParams.Linux,
		OSName:     osName,
		OSArch:     commonParams.Amd64,
		Status:     MapStatus(inst.State),
	}
	if inst.TailscaleIP != "" {
		ret.Addresses = []commonParams.Address{{Address: inst.TailscaleIP, Type: commonParams.PrivateAddress}}
	}
	if inst.State == srvStateFailed && inst.LastError != "" {
		ret.ProviderFault = []byte(inst.LastError)
	}
	return ret
}

// nameFor returns the GARM name for an instance: from its record if present,
// else from GARM_INSTANCE_ID when that is a name, else the provider ID.
func (p *Provider) nameFor(instance, id string) (string, error) {
	rec, err := p.store.Get(id)
	switch {
	case err == nil:
		return rec.Name, nil
	case !errors.Is(err, errRecordNotFound):
		return "", err
	case !IsProviderID(instance):
		return instance, nil
	default:
		return id, nil
	}
}

func (p *Provider) DeleteInstance(ctx context.Context, instance string) error {
	id := ResolveID(instance)
	lock, err := p.store.Lock(ctx, id)
	if err != nil {
		return err
	}
	if err := p.srv.Delete(ctx, id); err != nil && !errors.Is(err, errSrvNotFound) {
		lock.Unlock()
		return fmt.Errorf("deleting %s: %w", id, err)
	}
	if err := p.store.Delete(id); err != nil {
		lock.Unlock()
		return err
	}
	lock.UnlockAndRemove()
	return nil
}

func (p *Provider) GetInstance(ctx context.Context, instance string) (commonParams.ProviderInstance, error) {
	id := ResolveID(instance)
	inst, err := p.srv.Inspect(ctx, id)
	if errors.Is(err, errSrvNotFound) || (err == nil && inst.State == srvStateDeleted) {
		return commonParams.ProviderInstance{}, fmt.Errorf("instance %s (%s): %w", instance, id, garmErrors.ErrNotFound)
	}
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	name, err := p.nameFor(instance, id)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	return toProviderInstance(name, inst), nil
}

func (p *Provider) ListInstances(ctx context.Context, poolID string) ([]commonParams.ProviderInstance, error) {
	return p.list(ctx, func(r Record) bool { return r.PoolID == poolID })
}

// list returns this controller's instances whose record matches keep. A
// record whose VM is gone from srv and whose lock is free (no create or
// delete in flight) is stale: GARM drops such runners without calling
// DeleteInstance, so the record is pruned here.
func (p *Provider) list(ctx context.Context, keep func(Record) bool) ([]commonParams.ProviderInstance, error) {
	recs, err := p.store.List()
	if err != nil {
		return nil, err
	}
	ret := []commonParams.ProviderInstance{}
	var mine []Record
	for _, r := range recs {
		if r.ControllerID == p.controllerID && keep(r) {
			mine = append(mine, r)
		}
	}
	if len(mine) == 0 {
		return ret, nil
	}
	insts, err := p.srv.List(ctx)
	if err != nil {
		return nil, err
	}
	byName := make(map[string]SrvInstance, len(insts))
	for _, inst := range insts {
		byName[inst.Name] = inst
	}
	for _, r := range mine {
		if inst, ok := byName[r.ProviderID]; ok && inst.State != srvStateDeleted {
			ret = append(ret, toProviderInstance(r.Name, inst))
			continue
		}
		if err := p.pruneIfGone(ctx, r.ProviderID); err != nil {
			return nil, err
		}
	}
	return ret, nil
}

func (p *Provider) pruneIfGone(ctx context.Context, id string) error {
	lock, ok, err := p.store.TryLock(id)
	if err != nil || !ok {
		return err
	}
	// Re-check under the lock: a create may have finished since srv list.
	inst, err := p.srv.Inspect(ctx, id)
	if err == nil && inst.State != srvStateDeleted {
		lock.Unlock()
		return nil
	}
	if err != nil && !errors.Is(err, errSrvNotFound) {
		lock.Unlock()
		return err
	}
	if err := p.store.Delete(id); err != nil {
		lock.Unlock()
		return err
	}
	lock.UnlockAndRemove()
	return nil
}

func (p *Provider) RemoveAllInstances(ctx context.Context) error {
	recs, err := p.store.List()
	if err != nil {
		return err
	}
	var errs []error
	for _, r := range recs {
		if r.ControllerID != p.controllerID {
			continue
		}
		if err := p.DeleteInstance(ctx, r.ProviderID); err != nil {
			errs = append(errs, fmt.Errorf("%s (%s): %w", r.Name, r.ProviderID, err))
		}
	}
	return errors.Join(errs...)
}

func (p *Provider) inspectExisting(ctx context.Context, instance string) (string, SrvInstance, error) {
	id := ResolveID(instance)
	inst, err := p.srv.Inspect(ctx, id)
	if errors.Is(err, errSrvNotFound) || (err == nil && inst.State == srvStateDeleted) {
		return id, SrvInstance{}, fmt.Errorf("instance %s (%s): %w", instance, id, garmErrors.ErrNotFound)
	}
	return id, inst, err
}

// Stop stops the VM; already stopped/stopping is success. srv stop is always
// a graceful shutdown, so force is ignored.
func (p *Provider) Stop(ctx context.Context, instance string, _ bool) error {
	id, inst, err := p.inspectExisting(ctx, instance)
	if err != nil {
		return err
	}
	switch inst.State {
	case srvStateStopped, srvStateStopping:
		return nil
	}
	return p.srv.Stop(ctx, id)
}

// Start starts a stopped VM, or asks srv to recheck one stuck in
// awaiting-tailnet. Running or provisioning VMs are left alone.
func (p *Provider) Start(ctx context.Context, instance string) error {
	id, inst, err := p.inspectExisting(ctx, instance)
	if err != nil {
		return err
	}
	switch inst.State {
	case srvStateStopped, srvStateAwaitingTailnet:
		return p.srv.Start(ctx, id)
	case srvStateReady, srvStateProvisioning:
		return nil
	default:
		return fmt.Errorf("cannot start %s from state %s", id, inst.State)
	}
}

func (p *Provider) GetVersion(context.Context) string {
	return Version
}

func (p *Provider) GetSupportedInterfaceVersions(context.Context) []string {
	return []string{execCommon.Version010, execCommon.Version011}
}

// ValidatePoolInfo checks whatever pool fields are provided. extraspecs is
// GARM_POOL_EXTRASPECS, which GARM sends base64-encoded.
func (p *Provider) ValidatePoolInfo(_ context.Context, image, flavor, _, extraspecs string) error {
	if flavor != "" {
		if _, err := ParseFlavor(flavor); err != nil {
			return err
		}
	}
	if image != "" {
		if err := ValidateImageName(image); err != nil {
			return err
		}
	}
	if extraspecs == "" {
		return nil
	}
	raw := []byte(extraspecs)
	if decoded, err := base64.StdEncoding.DecodeString(extraspecs); err == nil {
		raw = decoded
	}
	return parseExtraSpecs(raw)
}

func (p *Provider) GetConfigJSONSchema(context.Context) (string, error) {
	return configJSONSchema, nil
}

func (p *Provider) GetExtraSpecsJSONSchema(context.Context) (string, error) {
	return extraSpecsJSONSchema, nil
}

const configJSONSchema = `{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "garm-provider-srv config",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "srv_host": {"type": "string", "default": "srv", "description": "ssh destination of the srv control plane"},
    "default_image": {"type": "string", "default": "gha-runner", "pattern": "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", "description": "srv image used when the pool sets none"},
    "state_dir": {"type": "string", "default": "/var/lib/garm/provider-srv", "description": "absolute path for per-instance state records"},
    "ready_timeout": {"type": "string", "default": "5m", "description": "Go duration bounding the srv-ready and guest-ssh waits"}
  }
}`

const extraSpecsJSONSchema = `{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "garm-provider-srv extra specs",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "runner_install_template": {"type": "string", "contentEncoding": "base64", "description": "base64 Go template overriding the default runner install script"},
    "extra_context": {"type": "object", "additionalProperties": {"type": "string"}, "description": "extra variables for runner_install_template"}
  }
}`
