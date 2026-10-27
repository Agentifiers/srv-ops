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
type SrvInstance struct {
	Name          string `json:"name"`
	Image         string `json:"image"`
	State         string `json:"state"`
	TailscaleName string `json:"tailscale_name"`
	TailscaleIP   string `json:"tailscale_ip"`
	LastError     string `json:"last_error"`
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

// notFound maps srv's "instance ... does not exist" failure to errSrvNotFound.
func notFound(err error) error {
	var ce *CommandError
	if errors.As(err, &ce) && strings.Contains(ce.Stderr, "does not exist") {
		return fmt.Errorf("%w: %s", errSrvNotFound, strings.TrimSpace(ce.Stderr))
	}
	return err
}

// Inspect returns errSrvNotFound if srv does not know the instance.
func (s *Srv) Inspect(ctx context.Context, name string) (SrvInstance, error) {
	out, err := s.cmd(ctx, "--json", "inspect", name)
	if err != nil {
		return SrvInstance{}, notFound(err)
	}
	var resp struct {
		Instance SrvInstance `json:"instance"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return SrvInstance{}, fmt.Errorf("decoding srv inspect %s: %w", name, err)
	}
	return resp.Instance, nil
}

// List returns all non-deleted instances visible to us.
func (s *Srv) List(ctx context.Context) ([]SrvInstance, error) {
	out, err := s.cmd(ctx, "--json", "list")
	if err != nil {
		return nil, err
	}
	var resp struct {
		Instances []SrvInstance `json:"instances"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, fmt.Errorf("decoding srv list: %w", err)
	}
	return resp.Instances, nil
}

func (s *Srv) New(ctx context.Context, name, image string, flavor Flavor) error {
	args := append([]string{"new", name, "--image", image}, flavor.SrvArgs()...)
	_, err := s.cmd(ctx, args...)
	return err
}

// Delete returns errSrvNotFound if the instance does not exist.
func (s *Srv) Delete(ctx context.Context, name string) error {
	_, err := s.cmd(ctx, "delete", name)
	return notFound(err)
}

func (s *Srv) Start(ctx context.Context, name string) error {
	_, err := s.cmd(ctx, "start", name)
	return notFound(err)
}

func (s *Srv) Stop(ctx context.Context, name string) error {
	_, err := s.cmd(ctx, "stop", name)
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
