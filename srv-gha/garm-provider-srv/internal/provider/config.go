package provider

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

const (
	defaultSrvHost      = "srv"
	defaultImage        = "gha-runner"
	defaultStateDir     = "/var/lib/garm/provider-srv"
	defaultReadyTimeout = 5 * time.Minute
)

// Config is the provider configuration read from GARM_PROVIDER_CONFIG_FILE.
type Config struct {
	// SrvHost is the ssh destination of the srv control plane.
	SrvHost string `toml:"srv_host"`
	// DefaultImage is the srv image used when the pool does not set one.
	DefaultImage string `toml:"default_image"`
	// StateDir holds one JSON record (and lock file) per instance.
	StateDir string `toml:"state_dir"`
	// ReadyTimeout bounds each wait during CreateInstance: srv readiness and
	// guest Tailscale SSH reachability.
	ReadyTimeout Duration `toml:"ready_timeout"`
}

// Duration is a time.Duration that decodes from strings such as "5m".
type Duration struct {
	time.Duration
}

func (d *Duration) UnmarshalText(text []byte) error {
	v, err := time.ParseDuration(string(text))
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", text, err)
	}
	d.Duration = v
	return nil
}

func (d Duration) MarshalText() ([]byte, error) {
	return []byte(d.String()), nil
}

// LoadConfig reads and validates the TOML config at path. Unknown keys are
// rejected so typos do not silently fall back to defaults.
func LoadConfig(path string) (*Config, error) {
	cfg := &Config{
		SrvHost:      defaultSrvHost,
		DefaultImage: defaultImage,
		StateDir:     defaultStateDir,
		ReadyTimeout: Duration{defaultReadyTimeout},
	}
	md, err := toml.DecodeFile(path, cfg)
	if err != nil {
		return nil, fmt.Errorf("decoding %s: %w", path, err)
	}
	if undecoded := md.Undecoded(); len(undecoded) > 0 {
		keys := make([]string, 0, len(undecoded))
		for _, k := range undecoded {
			keys = append(keys, k.String())
		}
		sort.Strings(keys)
		return nil, fmt.Errorf("%s: unknown keys: %s", path, strings.Join(keys, ", "))
	}
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, nil
}

func (c *Config) Validate() error {
	if c.SrvHost == "" || strings.HasPrefix(c.SrvHost, "-") {
		return fmt.Errorf("srv_host must be a non-empty ssh destination")
	}
	if err := ValidateImageName(c.DefaultImage); err != nil {
		return fmt.Errorf("default_image: %w", err)
	}
	if !filepath.IsAbs(c.StateDir) {
		return fmt.Errorf("state_dir must be an absolute path")
	}
	if c.ReadyTimeout.Duration <= 0 {
		return fmt.Errorf("ready_timeout must be positive")
	}
	return nil
}
