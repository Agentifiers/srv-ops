# garm-provider-srv

GARM external provider that runs every GitHub Actions runner in its own srv
Firecracker microVM. It shells out to `ssh <srv_host> ...` for the control
plane and to Tailscale SSH (`ssh root@<vm>`) to start the runner installer.

Supports GARM external provider interface `v0.1.0` and `v0.1.1`
(`GARM_INTERFACE_VERSION`). With GARM v0.2.1 leave `interface_version` unset:
that release's v0.1.1 client treats every successful `ListInstances` as an
error.

## Build and install

```sh
go build -trimpath -o garm-provider-srv .
sudo install -D -o root -g root -m 0755 garm-provider-srv /usr/local/lib/garm/garm-provider-srv
```

GARM config:

```toml
[[provider]]
name = "srv"
provider_type = "external"
disable_jit_config = false
  [provider.external]
  provider_executable = "/usr/local/lib/garm/garm-provider-srv"
  config_file = "/etc/garm/provider-srv.toml"
```

## Provider config (`GARM_PROVIDER_CONFIG_FILE`)

```toml
srv_host = "srv"                          # ssh destination of srv (SRV_HOST in site.env)
default_image = "gha-runner"              # srv image when the pool sets none (GHA_RUNNER_IMAGE)
state_dir = "/var/lib/garm/provider-srv"  # per-instance records, created 0700
ready_timeout = "5m"                      # bound for srv-ready and for guest SSH
```

All keys are optional (the values above are the defaults); unknown keys are
rejected. The provider runs as GARM's user, which therefore needs
non-interactive SSH to `srv_host` and Tailscale SSH to `root@gha-*` guests,
plus a writable `~/.ssh/known_hosts`. GARM passes only `GARM_*` variables, so
the binary sets `PATH` itself when it is empty.

## Pools

- `flavor`: `<cpus>c-<ram>g-<disk>g`, e.g. `8c-16g-60g` becomes
  `srv new <id> --cpus 8 --ram 16G --rootfs-size 60G`.
- `image`: srv image name; empty means `default_image`.
- `os_type` linux, `os_arch` amd64.
- `extra_specs` (optional): `runner_install_template` (base64 Go template) and
  `extra_context` (string map), as understood by garm-provider-common's
  `cloudconfig`. Other keys are rejected.

## Behaviour

- srv names: `gha-` + first 16 hex chars of sha256(GARM runner name). GARM may
  pass either that ID or the runner name in `GARM_INSTANCE_ID`; both resolve
  to the same VM, and nothing without the `gha-` prefix is ever touched.
- State: `<state_dir>/<id>.json` holds name, provider_id, pool_id,
  controller_id, image, flavor and created_at; `<id>.lock` is a flock that
  serialises create/delete/prune across concurrent provider processes. The
  record is written before `srv new` and removed after a successful delete.
- `CreateInstance`: `srv new`, wait for state `ready`, wait for guest SSH,
  write the runner install script (from `cloudconfig.GetRunnerInstallScript`)
  over ssh stdin to `/run/garm/runner-install.sh` (0600) and start it with
  `systemd-run --unit=garm-runner-install --collect`. Any failure after
  `srv new` deletes the VM and record, prints an instance with
  `status: error` and `provider_fault`, and exits non-zero. Installer logs:
  `journalctl -u garm-runner-install` in the guest.
- `ListInstances` reports this controller's records for the pool. A record
  whose VM is gone from srv and that no other process holds locked is pruned
  (GARM forgets such runners without calling `DeleteInstance`).
- `GetInstance`/`StartInstance`/`StopInstance` on an unknown VM exit 30
  (not found). `DeleteInstance` of an unknown VM succeeds.
- Status mapping (GARM only accepts these from providers): `ready` →
  running; `stopped`, `stopping` → stopped; `failed` → error; everything
  else (`provisioning`, `awaiting-tailnet`, `deleting`) → unknown.
