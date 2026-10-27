package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "provider-srv.toml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadConfig(t *testing.T) {
	cfg, err := LoadConfig(writeConfig(t, `
srv_host = "srv"
default_image = "gha-runner"
state_dir = "/var/lib/garm/provider-srv"
ready_timeout = "7m"
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SrvHost != "srv" || cfg.DefaultImage != "gha-runner" || cfg.StateDir != "/var/lib/garm/provider-srv" || cfg.ReadyTimeout.Duration != 7*time.Minute {
		t.Fatalf("cfg = %+v", cfg)
	}

	cfg, err = LoadConfig(writeConfig(t, ""))
	if err != nil || cfg.ReadyTimeout.Duration != 5*time.Minute || cfg.DefaultImage != "gha-runner" {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	for body, want := range map[string]string{
		`srv_hots = "srv"`:       "unknown keys",
		`ready_timeout = "soon"`: "invalid duration",
		`ready_timeout = "-1s"`:  "ready_timeout",
		`state_dir = "relative"`: "state_dir",
		`default_image = "Bad"`:  "default_image",
		`srv_host = "-oProxy=x"`: "srv_host",
	} {
		if _, err := LoadConfig(writeConfig(t, body)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("LoadConfig(%q) = %v, want error containing %q", body, err, want)
		}
	}
}
