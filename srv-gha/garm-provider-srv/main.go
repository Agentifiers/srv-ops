// Command garm-provider-srv is a GARM external provider that runs each
// runner in an srv Firecracker microVM.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/cloudbase/garm-provider-common/execution"
	execCommon "github.com/cloudbase/garm-provider-common/execution/common"

	"github.com/Agentifiers/srv-ops/srv-gha/garm-provider-srv/internal/provider"
)

// GARM execs providers with only GARM_* variables (plus any configured
// environment_variables), so PATH is usually unset; ssh must still resolve.
const defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"

func main() {
	os.Exit(run())
}

func run() int {
	if os.Getenv("PATH") == "" {
		os.Setenv("PATH", defaultPath)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	env, err := execution.GetEnvironment()
	if err != nil {
		fmt.Fprintf(os.Stderr, "garm-provider-srv: %v\n", err)
		return 1
	}
	cfg, err := provider.LoadConfig(env.ProviderConfigFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "garm-provider-srv: %v\n", err)
		return 1
	}
	prov := provider.NewProvider(cfg, env.ControllerID, provider.ExecRunner)

	result, err := env.Run(ctx, prov)
	if err != nil {
		var createErr *provider.CreateError
		if errors.As(err, &createErr) {
			if js, mErr := json.Marshal(createErr.Instance); mErr == nil {
				fmt.Println(string(js))
			}
		}
		fmt.Fprintf(os.Stderr, "garm-provider-srv: %v\n", err)
		return execCommon.ResolveErrorToExitCode(err)
	}
	if result != "" {
		fmt.Print(result)
	}
	return 0
}
