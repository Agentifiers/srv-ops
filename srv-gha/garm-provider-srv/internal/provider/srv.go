package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	commonParams "github.com/cloudbase/garm-provider-common/params"
)

// srv instance states (vendor/srv internal/model).
const (
	srvStateProvisioning    = "provisioning"
	srvStateReady           = "ready"
	srvStateStopping        = "stopping"
	srvStateStopped         = "stopped"
	srvStateFailed          = "failed"
	srvStateAwaitingTailnet = "awaiting-tailnet"
	srvStateDeleting        = "deleting"
	srvStateDeleted         = "deleted"
)

// errSrvNotFound reports that srv has no such instance.
var errSrvNotFound = errors.New("srv instance does not exist")

// CommandError is a failed external command with its stderr.
type CommandError struct {
	Args   []string
	Stderr string
	Err    error
}

func (e *CommandError) Error() string {
	msg := strings.TrimSpace(e.Stderr)
	if msg == "" {
		return fmt.Sprintf("%s: %v", strings.Join(e.Args, " "), e.Err)
	}
	return fmt.Sprintf("%s: %v: %s", strings.Join(e.Args, " "), e.Err, msg)
}

func (e *CommandError) Unwrap() error { return e.Err }

// Runner executes a command with optional stdin and returns its stdout. A
// non-zero exit must surface as *CommandError so callers can inspect stderr.
type Runner func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error)

// ExecRunner runs commands via os/exec.
func ExecRunner(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), &CommandError{Args: append([]string{name}, args...), Stderr: stderr.String(), Err: err}
	}
	return stdout.Bytes(), nil
}

// SrvInstance is the subset of srv's instance JSON this provider uses. It
// matches both `--json inspect` (.instance) and `--json list` (.instances[]).
// Host is the srv-front host that reported the instance; it is empty when
// srv_host is a single backend.
type SrvInstance struct {
	Name          string `json:"name"`
	Image         string `json:"image"`
	State         string `json:"state"`
	TailscaleName string `json:"tailscale_name"`
	TailscaleIP   string `json:"tailscale_ip"`
	LastError     string `json:"last_error"`
	Host          string `json:"-"`
}

// Target is the name srv commands address an instance by: host/name once the
// instance's srv-front host is known, else the bare name, which a single
// backend takes as is and srv-front resolves by asking every host.
func Target(name, host string) string {
	if host == "" {
		return name
	}
	return host + "/" + name
}

// Srv talks to the srv control plane over ssh.
type Srv struct {
	host string
	run  Runner
}

func NewSrv(host string, run Runner) *Srv {
	return &Srv{host: host, run: run}
}

func (s *Srv) cmd(ctx context.Context, args ...string) ([]byte, error) {
	sshArgs := append([]string{"-o", "BatchMode=yes", "-o", "ConnectTimeout=10", s.host, "--"}, args...)
	return s.run(ctx, nil, "ssh", sshArgs...)
}

// notFound maps a definite absence to errSrvNotFound: a backend's "instance
// ... does not exist" (also when relayed by srv-front for host/name), or
// srv-front's "resolves to 0 hosts", which it reports only after every host
// answered. An unreachable host is an error, never absence.
func notFound(err error) error {
	var ce *CommandError
	if errors.As(err, &ce) && (strings.Contains(ce.Stderr, "does not exist") || strings.Contains(ce.Stderr, "resolves to 0 hosts")) {
		return fmt.Errorf("%w: %s", errSrvNotFound, strings.TrimSpace(ce.Stderr))
	}
	return err
}

// Inspect returns errSrvNotFound if srv does not know the instance. target
// is a name or host/name (see Target).
func (s *Srv) Inspect(ctx context.Context, target string) (SrvInstance, error) {
	out, err := s.cmd(ctx, "--json", "inspect", target)
	if err != nil {
		return SrvInstance{}, notFound(err)
	}
	var resp struct {
		Instance SrvInstance `json:"instance"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return SrvInstance{}, fmt.Errorf("decoding srv inspect %s: %w", target, err)
	}
	return resp.Instance, nil
}

// List returns all non-deleted instances visible to us. srv_host may be a
// single backend ({"instances":[...]}) or srv-front ({"hosts":[{"host",
// "data":{"instances":[...]},"error"}]}); with srv-front every host must
// answer, because a missing host's runners would otherwise look deleted.
func (s *Srv) List(ctx context.Context) ([]SrvInstance, error) {
	out, err := s.cmd(ctx, "--json", "list")
	if err != nil {
		return nil, err
	}
	var resp struct {
		Instances *[]SrvInstance `json:"instances"`
		Hosts     []struct {
			Host  string `json:"host"`
			Error string `json:"error"`
			Data  struct {
				Instances *[]SrvInstance `json:"instances"`
			} `json:"data"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, fmt.Errorf("decoding srv list: %w", err)
	}
	switch {
	case resp.Instances != nil:
		return *resp.Instances, nil
	case len(resp.Hosts) > 0:
		var all []SrvInstance
		for _, h := range resp.Hosts {
			if h.Error != "" || h.Host == "" || h.Data.Instances == nil {
				return nil, fmt.Errorf("srv list: incomplete inventory from host %q: %s", h.Host, h.Error)
			}
			for _, inst := range *h.Data.Instances {
				inst.Host = h.Host
				all = append(all, inst)
			}
		}
		return all, nil
	default:
		return nil, errors.New("srv list: response has neither instances nor hosts")
	}
}

// Locate returns the srv-front host holding name, or "" when srv_host is a
// single backend or name is not listed (yet).
func (s *Srv) Locate(ctx context.Context, name string) (string, error) {
	insts, err := s.List(ctx)
	if err != nil {
		return "", err
	}
	for _, inst := range insts {
		if inst.Name == name {
			return inst.Host, nil
		}
	}
	return "", nil
}

func (s *Srv) New(ctx context.Context, name, image string, flavor Flavor) error {
	args := append([]string{"new", name, "--image", image}, flavor.SrvArgs()...)
	_, err := s.cmd(ctx, args...)
	return err
}

// Delete returns errSrvNotFound if the instance does not exist.
func (s *Srv) Delete(ctx context.Context, target string) error {
	_, err := s.cmd(ctx, "delete", target)
	return notFound(err)
}

func (s *Srv) Start(ctx context.Context, target string) error {
	_, err := s.cmd(ctx, "start", target)
	return notFound(err)
}

func (s *Srv) Stop(ctx context.Context, target string) error {
	_, err := s.cmd(ctx, "stop", target)
	return notFound(err)
}

// MapStatus converts an srv state to a GARM provider status. GARM v0.2.1
// rejects (ValidateResult) anything but running, stopped, error and unknown
// from a provider, so transitional states map to unknown.
func MapStatus(state string) commonParams.InstanceStatus {
	switch state {
	case srvStateReady:
		return commonParams.InstanceRunning
	case srvStateStopped, srvStateStopping:
		return commonParams.InstanceStopped
	case srvStateFailed:
		return commonParams.InstanceError
	default:
		// provisioning, awaiting-tailnet, deleting, or anything newer.
		return commonParams.InstanceStatusUnknown
	}
}
