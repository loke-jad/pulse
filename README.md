# pulse

Per-host system health snapshots in Markdown + TOML.

## What it is

`pulse` is a single bash script that takes a snapshot of a Linux host and writes
two files: a human-readable Markdown report and a machine-parseable TOML report.
It is designed to be run periodically (cron, systemd timer) on each machine in a
small homelab fleet, building a rolling history of host state on disk.

Each run captures:

- **Hardware**: CPU model + core count, load averages (1/5/15), memory + swap
  usage, mounted disk usage (filtered to non-virtual filesystems), GPU state
  (NVIDIA via `nvidia-smi`, AMD via `/sys/class/drm`, temperature via
  `sensors`), and uptime.
- **Services**: systemd system + user units (active/failed only, with noisy
  units like `dbus-`, `getty`, `pipewire` filtered out), Docker containers
  (status + listening ports), Podman containers, Kubernetes pods (when
  `kubectl` reaches a cluster), and Ollama models including any currently
  loaded into VRAM.
- **Network**: non-virtual interfaces and their addresses, Tailscale state +
  peers, WireGuard interface + peer count, configured DNS resolvers and
  whether DNS-over-TLS is in use, ping latency to Cloudflare/Google plus any
  hosts you configure via `PULSE_PING_HOSTS`, plus all listening TCP ports
  with the owning process.
- **APIs & MCPs**: probes each listening port in 1000–50000 with a 1-second
  timeout, identifying HTTP, Ollama/LLM, Vault, and LocalAI endpoints. Will
  optionally enrich entries with metadata from a local API catalog directory.
- **Errors since last pulse**: dedup'd error-priority entries from
  `journalctl` (system + user), with kernel memory-pressure noise filtered
  out, and any unhealthy/restarting Docker containers.

Output filenames: `<hostname>-HH-MM_DD-MM-YY.{md,toml}`.

Files go to `~/.pulse/<hostname>/` by default. If `PULSE_KB_DIR` exists (or its
default `/mnt/KB/state/pulse`), copies are synced there as well, so a shared
mount can act as a fleet-wide archive. The script keeps the newest 32 files per
format per directory and deletes older ones.

## Status

Production for a small homelab fleet (5 hosts). Bash 4+ only, Linux only,
untested on macOS/BSD. Some sections (GPU, Tailscale, WireGuard, Docker, k8s,
Ollama) only emit output when the relevant tool is on `PATH`, so a minimal
host produces a minimal report — that's by design.

## Install

```bash
sudo cp pulse.sh /usr/local/bin/pulse
sudo chmod +x /usr/local/bin/pulse
```

Or use the included `install.sh` (same thing, one step).

Run it every 15 minutes from cron:

```cron
*/15 * * * * /usr/local/bin/pulse >/dev/null 2>&1
```

## Configuration

All configuration is via environment variables — no config file.

| Variable            | Default                       | Purpose                                                          |
|---------------------|-------------------------------|------------------------------------------------------------------|
| `PULSE_DIR`         | `$HOME/.pulse/<hostname>`     | Where snapshots are written locally.                             |
| `PULSE_KB_DIR`      | `/mnt/KB/state/pulse`         | Optional shared-archive root. Sync only happens if it exists.    |
| `PULSE_PING_HOSTS`  | _(unset)_                     | Extra ping targets, format `label1=host1,label2=host2`.          |
| `PULSE_CATALOG_DIR` | `$HOME/api-catalog/cards`     | Optional API catalog dir for enriching detected services.        |

`MAX_FILES` (rotation cap) is a constant near the top of the script — change
the line `MAX_FILES=32` if you want more or fewer history entries kept.

To disable the shared-archive sync entirely, set `PULSE_KB_DIR` to a path that
doesn't exist (e.g. `PULSE_KB_DIR=/dev/null/disabled`).

## Output sample

Markdown excerpt:

```markdown
# Pulse — myhost — 2026-04-24T14:32:11+00:00

## Hardware

- **CPU**: AMD Ryzen 7 5800X 8-Core Processor (16 cores)
- **Load**: 0.42 0.38 0.31
- **Memory**: 7.8Gi / 31Gi
- **Swap**: 0B / 8.0Gi
- **Disks**:
  - /: 142G/466G (33%)
- **Uptime**: 4 days, 7 hours, 12 minutes

## Services

### Docker
| Container | Status | Ports |
|-----------|--------|-------|
| caddy     | up     | 80,443 |
| postgres  | up     | 5432   |
```

TOML excerpt:

```toml
[meta]
hostname = "myhost"
timestamp = "2026-04-24T14:32:11+00:00"
last_pulse = "2026-04-24T14:17:08+00:00"

[hardware]
cpu = "AMD Ryzen 7 5800X 8-Core Processor"
cores = 16
load = [0.42, 0.38, 0.31]
memory_used_mb = 7987
memory_total_mb = 31742
uptime_seconds = 371532

[[hardware.disks]]
device = "/dev/nvme0n1p2"
mount = "/"
used = "142G"
total = "466G"
percent = "33%"

[[network.ping]]
target = "Cloudflare"
host = "1.1.1.1"
ms = 4.21
vpn = "no"
```

## Known limitations

- Bash 4+, Linux-only. No Windows, untested on macOS/BSD.
- Depends on common Linux tools — `ss`, `ip`, `df`, `free`, `journalctl`,
  `awk`, `grep`. Busybox-light environments will produce degraded output.
- `python3` is used for two narrow JSON parses (Tailscale status, Kubernetes
  pod list). Those sections silently degrade if Python is absent.
- No central dashboard, no alerting, no aggregation. This script writes files;
  consuming them is your problem.
- Snapshots are plain files, not authenticated or encrypted. Don't write them
  to a network mount you wouldn't trust with the contents of `ss -tlnp`.
- Port-probing scans every listening TCP port between 1000 and 50000 with a
  1-second curl timeout. On a host with many open ports this can add several
  seconds per run.
- `MAX_FILES=32` is a hardcoded constant, not an env var (yet).

## License

Apache-2.0. See [LICENSE](LICENSE).
