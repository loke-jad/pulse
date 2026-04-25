#!/usr/bin/env bash
# pulse — system-wide health snapshot
# Runs on any machine. Outputs .md (human) and .toml (machine) reports.
# Filename: hostname-HH-MM_DD-MM-YY.{md,toml}
# Keeps max 32 reports per format, rotates oldest.

set -uo pipefail

HOSTNAME=$(hostname -s)
TIMESTAMP=$(date -Iseconds)
FNAME="${HOSTNAME}-$(date +%H-%M_%d-%m-%y)"

# Output dirs — local always, KB if mounted
LOCAL_DIR="${PULSE_DIR:-$HOME/.pulse/$HOSTNAME}"
KB_DIR="${PULSE_KB_DIR:-/mnt/KB/state/pulse}/$HOSTNAME"
MAX_FILES=32

mkdir -p "$LOCAL_DIR"
[ -d "$(dirname "$KB_DIR")" ] && mkdir -p "$KB_DIR" 2>/dev/null || true

MD_FILE="$LOCAL_DIR/$FNAME.md"
TOML_FILE="$LOCAL_DIR/$FNAME.toml"

# Temp files for building output
MD=$(mktemp)
TOML=$(mktemp)
trap 'rm -f "$MD" "$TOML"' EXIT

# --- Helpers ---

cmd_exists() { command -v "$1" &>/dev/null; }

# Get last pulse timestamp for error window
last_pulse_time() {
    local latest
    latest=$(ls -t "$LOCAL_DIR"/*.toml 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        grep '^timestamp' "$latest" 2>/dev/null | head -1 | cut -d'"' -f2
    else
        date -d '3 hours ago' -Iseconds 2>/dev/null || date -Iseconds
    fi
}

LAST_PULSE=$(last_pulse_time)

# ============================================================
# TOML HEADER
# ============================================================
cat >> "$TOML" << EOF
[meta]
hostname = "$HOSTNAME"
timestamp = "$TIMESTAMP"
last_pulse = "$LAST_PULSE"

EOF

# ============================================================
# MARKDOWN HEADER
# ============================================================
cat >> "$MD" << EOF
# Pulse — $HOSTNAME — $TIMESTAMP

EOF

# ============================================================
# 1. HARDWARE
# ============================================================
{
    echo "## Hardware"
    echo ""

    # CPU
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    cpu_cores=$(nproc 2>/dev/null || echo "?")
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    echo "- **CPU**: $cpu_model ($cpu_cores cores)"
    echo "- **Load**: $load"

    # Memory
    mem_total=$(free -h | awk '/Mem:/{print $2}')
    mem_used=$(free -h | awk '/Mem:/{print $3}')
    swap_total=$(free -h | awk '/Swap:/{print $2}')
    swap_used=$(free -h | awk '/Swap:/{print $3}')
    echo "- **Memory**: $mem_used / $mem_total"
    echo "- **Swap**: $swap_used / $swap_total"

    # Disk
    echo "- **Disks**:"
    df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print "  - " $6 ": " $3 "/" $2 " (" $5 ")"}'

    # GPU
    if cmd_exists nvidia-smi; then
        gpu_info=$(nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        echo "- **GPU (NVIDIA)**: $gpu_info"
    fi
    if [ -f /sys/class/drm/card0/device/mem_info_vram_used ] 2>/dev/null; then
        vram_used=$(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null)
        vram_total=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null)
        if [ -n "$vram_used" ] && [ -n "$vram_total" ]; then
            vram_used_gb=$(echo "scale=1; $vram_used / 1073741824" | bc 2>/dev/null || echo "?")
            vram_total_gb=$(echo "scale=1; $vram_total / 1073741824" | bc 2>/dev/null || echo "?")
            echo "- **GPU (AMD)**: ${vram_used_gb}GB / ${vram_total_gb}GB VRAM"
        fi
    fi
    if cmd_exists sensors; then
        gpu_temp=$(sensors 2>/dev/null | grep -i 'junction\|edge\|GPU' | head -1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
        [ -n "$gpu_temp" ] && echo "- **GPU Temp**: ${gpu_temp}C"
    fi

    # Uptime
    echo "- **Uptime**: $(uptime -p 2>/dev/null | sed 's/up //')"
    echo ""
} >> "$MD"

# TOML hardware
{
    load1=$(cat /proc/loadavg | awk '{print $1}')
    load5=$(cat /proc/loadavg | awk '{print $2}')
    load15=$(cat /proc/loadavg | awk '{print $3}')
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_used_kb=$((mem_total_kb - mem_avail_kb))
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_used_kb=$((swap_total_kb - $(grep SwapFree /proc/meminfo | awk '{print $2}')))

    cat >> "$TOML" << EOF
[hardware]
cpu = "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)"
cores = $cpu_cores
load = [$load1, $load5, $load15]
memory_used_mb = $((mem_used_kb / 1024))
memory_total_mb = $((mem_total_kb / 1024))
swap_used_mb = $((swap_used_kb / 1024))
swap_total_mb = $((swap_total_kb / 1024))
uptime_seconds = $(cat /proc/uptime | awk '{printf "%d", $1}')

EOF

    # Disks as TOML array
    echo "[[hardware.disks]]" >> /dev/null  # placeholder pattern
    df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{
        gsub(/"/, "\\\"", $1);
        gsub(/"/, "\\\"", $6);
        print "[[hardware.disks]]"
        print "device = \"" $1 "\""
        print "mount = \"" $6 "\""
        print "used = \"" $3 "\""
        print "total = \"" $2 "\""
        print "percent = \"" $5 "\""
        print ""
    }' >> "$TOML"

    # GPU VRAM
    if [ -f /sys/class/drm/card0/device/mem_info_vram_used ] 2>/dev/null; then
        vram_u=$(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 0)
        vram_t=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo 0)
        echo "gpu_vram_used_bytes = $vram_u" >> "$TOML"
        echo "gpu_vram_total_bytes = $vram_t" >> "$TOML"
    fi
    echo "" >> "$TOML"
}

# ============================================================
# 2. SERVICES
# ============================================================
{
    echo "## Services"
    echo ""
} >> "$MD"
echo "[services]" >> "$TOML"
echo "" >> "$TOML"

# --- Systemd (system) ---
{
    echo "### Systemd (system)"
    echo "| Service | Status |"
    echo "|---------|--------|"
    systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | \
        grep -v 'systemd-\|dbus-\|user@\|-.mount\|modprobe\|udev\|getty\|fstrim' | \
        awk '/\.service/{
            name=$1; sub(/\.service$/,"",name);
            status=$3;
            if(status=="active" || status=="failed")
                print "| " name " | " status " |"
        }' | sort
    echo ""
} >> "$MD"

systemctl list-units --type=service --all --no-pager --plain 2>/dev/null | \
    grep -v 'systemd-\|dbus-\|user@\|-.mount\|modprobe\|udev\|getty\|fstrim' | \
    awk '/\.service/{
        name=$1; sub(/\.service$/,"",name);
        status=$3;
        if(status=="active" || status=="failed") {
            gsub(/"/, "\\\"", name);
            print "[[services.systemd]]"
            print "name = \"" name "\""
            print "status = \"" status "\""
            print ""
        }
    }' >> "$TOML"

# --- Systemd (user) ---
{
    echo "### Systemd (user)"
    echo "| Service | Status |"
    echo "|---------|--------|"
    systemctl --user list-units --type=service --all --no-pager --plain 2>/dev/null | \
        grep -v 'dbus-\|at-spi\|pipewire\|wireplumber\|xdg-\|dconf\|gvfs\|gnome-keyring\|app-' | \
        awk '/\.service/{
            name=$1; sub(/\.service$/,"",name);
            status=$3;
            if(status=="active" || status=="failed")
                print "| " name " | " status " |"
        }' | sort
    echo ""
} >> "$MD"

systemctl --user list-units --type=service --all --no-pager --plain 2>/dev/null | \
    grep -v 'dbus-\|at-spi\|pipewire\|wireplumber\|xdg-\|dconf\|gvfs\|gnome-keyring\|app-' | \
    awk '/\.service/{
        name=$1; sub(/\.service$/,"",name);
        status=$3;
        if(status=="active" || status=="failed") {
            gsub(/"/, "\\\"", name);
            print "[[services.systemd_user]]"
            print "name = \"" name "\""
            print "status = \"" status "\""
            print ""
        }
    }' >> "$TOML"

# --- Docker ---
if cmd_exists docker; then
    {
        echo "### Docker"
        echo "| Container | Status | Ports |"
        echo "|-----------|--------|-------|"
        docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sort | while IFS=$'\t' read -r name status ports; do
            # Normalize status to up/down/unhealthy
            state="down"
            [[ "$status" == Up* ]] && state="up"
            [[ "$status" == *unhealthy* ]] && state="unhealthy"
            [[ "$status" == *healthy* ]] && [[ "$status" != *unhealthy* ]] && state="up"
            # Extract just the port mappings
            clean_ports=$(echo "$ports" | sed 's/0\.0\.0\.0://g; s/127\.0\.0\.1://g; s/\[::\]://g' | tr ',' '\n' | grep -oP '^\d+' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
            echo "| $name | $state | $clean_ports |"
        done
        echo ""
    } >> "$MD"

    docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Ports}}' 2>/dev/null | sort | while IFS=$'\t' read -r name state ports; do
        clean_ports=$(echo "$ports" | sed 's/0\.0\.0\.0://g; s/127\.0\.0\.1://g; s/\[::\]://g' | tr ',' '\n' | grep -oP '^\d+' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
        cat >> "$TOML" << EOF
[[services.docker]]
name = "$name"
status = "$state"
ports = "$clean_ports"

EOF
    done
fi

# --- Podman ---
if cmd_exists podman; then
    {
        echo "### Podman"
        echo "| Container | Status | Ports |"
        echo "|-----------|--------|-------|"
        podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sort | while IFS=$'\t' read -r name status ports; do
            state="down"
            [[ "$status" == Up* ]] && state="up"
            [[ "$status" == *unhealthy* ]] && state="unhealthy"
            echo "| $name | $state | $ports |"
        done
        echo ""
    } >> "$MD"

    podman ps -a --format '{{.Names}}\t{{.State}}\t{{.Ports}}' 2>/dev/null | sort | while IFS=$'\t' read -r name state ports; do
        cat >> "$TOML" << EOF
[[services.podman]]
name = "$name"
status = "$state"
ports = "$ports"

EOF
    done
fi

# --- Kubernetes ---
if cmd_exists kubectl && kubectl cluster-info &>/dev/null 2>&1; then
    {
        echo "### Kubernetes"
        echo "| Namespace | Pod | Status | Restarts |"
        echo "|-----------|-----|--------|----------|"
        kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '{print "| " $1 " | " $2 " | " $4 " | " $5 " |"}'
        echo ""
    } >> "$MD"

    kubectl get pods --all-namespaces --no-headers -o json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for pod in data.get('items', []):
        ns = pod['metadata']['namespace']
        name = pod['metadata']['name']
        phase = pod['status'].get('phase', 'Unknown')
        restarts = sum(cs.get('restartCount', 0) for cs in pod['status'].get('containerStatuses', []))
        print(f'[[services.kubernetes]]')
        print(f'namespace = \"{ns}\"')
        print(f'name = \"{name}\"')
        print(f'status = \"{phase}\"')
        print(f'restarts = {restarts}')
        print()
except: pass
" >> "$TOML" 2>/dev/null || true
fi

# --- Ollama models ---
if cmd_exists ollama; then
    {
        echo "### Ollama Models"
        echo "| Model | Size |"
        echo "|-------|------|"
        ollama list 2>/dev/null | tail -n +2 | awk '{print "| " $1 " | " $3 " " $4 " |"}'
        echo ""
        # Currently loaded
        loaded=$(ollama ps 2>/dev/null | tail -n +2)
        if [ -n "$loaded" ]; then
            echo "**Loaded in VRAM**:"
            echo "$loaded" | awk '{print "- " $1 " (" $3 " " $4 ", " $5 " " $6 ")"}'
            echo ""
        fi
    } >> "$MD"

    ollama list 2>/dev/null | tail -n +2 | awk '{
        gsub(/"/, "\\\"", $1);
        print "[[services.ollama_models]]"
        print "name = \"" $1 "\""
        print "size = \"" $3 " " $4 "\""
        print ""
    }' >> "$TOML"
fi

# ============================================================
# 3. NETWORK
# ============================================================
{
    echo "## Network"
    echo ""
} >> "$MD"
echo "[network]" >> "$TOML"
echo "" >> "$TOML"

# Interfaces (skip veth, docker bridges, loopback)
{
    echo "### Interfaces"
    echo "| Interface | Address | State |"
    echo "|-----------|---------|-------|"
    ip -br addr show 2>/dev/null | while read -r iface state addrs; do
        [[ "$iface" == lo || "$iface" == veth* || "$iface" == br-* || "$iface" == docker* ]] && continue
        echo "| $iface | $addrs | $state |"
    done
    echo ""
} >> "$MD"

ip -br addr show 2>/dev/null | while read -r iface state addrs; do
    [[ "$iface" == lo || "$iface" == veth* || "$iface" == br-* || "$iface" == docker* ]] && continue
    cat >> "$TOML" << EOF
[[network.interfaces]]
name = "$iface"
state = "$state"
addresses = "$addrs"

EOF
done

# Tailscale
if cmd_exists tailscale; then
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    ts_status=$(tailscale status --json 2>/dev/null)
    if [ -n "$ts_ip" ]; then
        {
            echo "### Tailscale"
            echo "- **IP**: $ts_ip"
            echo "- **Status**: $(echo "$ts_status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','unknown'))" 2>/dev/null || echo "unknown")"
            echo "- **Peers**:"
            tailscale status 2>/dev/null | tail -n +2 | grep -v '^#\|^$\|Health' | while read -r ip name _ os _ relay _; do
                [[ "$ip" == "-" || -z "$ip" || "$ip" == "#" ]] && continue
                echo "  - $name ($ip) — $os"
            done
            echo ""
        } >> "$MD"

        echo "tailscale_ip = \"$ts_ip\"" >> "$TOML"
        echo "tailscale_state = \"$(echo "$ts_status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','unknown'))" 2>/dev/null || echo "unknown")\"" >> "$TOML"
        echo "" >> "$TOML"
    fi
fi

# Wireguard
if cmd_exists wg; then
    wg_out=$(sudo wg show 2>/dev/null || wg show 2>/dev/null || true)
    if [ -n "$wg_out" ]; then
        {
            echo "### Wireguard"
            echo '```'
            echo "$wg_out" | head -30
            echo '```'
            echo ""
        } >> "$MD"

        wg_iface=$(echo "$wg_out" | grep 'interface:' | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        wg_peers=$(echo "$wg_out" | grep -c 'peer:' || echo 0)
        echo "wireguard_interface = \"$wg_iface\"" >> "$TOML"
        echo "wireguard_peers = $wg_peers" >> "$TOML"
        echo "" >> "$TOML"
    fi
fi

# DNS
{
    echo "### DNS"
    dns_servers=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
    echo "- **Servers**: $dns_servers"

    # Check if DNS is encrypted (systemd-resolved with DoT/DoH)
    dns_encrypted="no"
    if cmd_exists resolvectl; then
        dot_status=$(resolvectl status 2>/dev/null | grep -i 'DNSOverTLS\|DNS over TLS' | head -1 | xargs)
        [ -n "$dot_status" ] && dns_encrypted="$dot_status"
    fi
    echo "- **Encrypted**: $dns_encrypted"
    echo ""
} >> "$MD"

echo "dns_servers = \"$dns_servers\"" >> "$TOML"
echo "dns_encrypted = \"$dns_encrypted\"" >> "$TOML"
echo "" >> "$TOML"

# Connectivity / ping tests
{
    echo "### Connectivity"
    echo "| Target | Ping (ms) | Via VPN |"
    echo "|--------|-----------|---------|"

    ping_test() {
        local host=$1 label=$2 vpn=$3
        local ms
        ms=$(ping -c1 -W2 "$host" 2>/dev/null | grep 'time=' | grep -oP 'time=\K[0-9.]+')
        if [ -n "$ms" ]; then
            echo "| $label ($host) | ${ms} | $vpn |"
            echo "[[network.ping]]" >> "$TOML"
            echo "target = \"$label\"" >> "$TOML"
            echo "host = \"$host\"" >> "$TOML"
            echo "ms = $ms" >> "$TOML"
            echo "vpn = \"$vpn\"" >> "$TOML"
            echo "" >> "$TOML"
        else
            echo "| $label ($host) | UNREACHABLE | $vpn |"
            echo "[[network.ping]]" >> "$TOML"
            echo "target = \"$label\"" >> "$TOML"
            echo "host = \"$host\"" >> "$TOML"
            echo "ms = -1" >> "$TOML"
            echo "vpn = \"$vpn\"" >> "$TOML"
            echo "" >> "$TOML"
        fi
    }

    ping_test "1.1.1.1" "Cloudflare" "no"
    ping_test "8.8.8.8" "Google DNS" "no"

    # Optional: ping additional hosts via PULSE_PING_HOSTS env var.
    # Format: "label1=host1,label2=host2"  (e.g. "gateway=192.0.2.1,nas=192.0.2.10")
    if [ -n "${PULSE_PING_HOSTS:-}" ]; then
        IFS=',' read -ra _entries <<< "$PULSE_PING_HOSTS"
        for entry in "${_entries[@]}"; do
            label="${entry%%=*}"
            host="${entry#*=}"
            [ -n "$label" ] && [ -n "$host" ] && ping_test "$host" "$label" "no"
        done
    fi

    # Tailscale peers
    if cmd_exists tailscale; then
        tailscale status 2>/dev/null | tail -n +2 | grep -v '^#\|^$\|Health' | awk '{print $1, $2}' | while read -r ip name; do
            [[ -z "$ip" || "$ip" == "-" || "$ip" == "#" ]] && continue
            [ -n "$name" ] && ping_test "$ip" "$name" "tailscale"
        done
    fi

    echo ""
} >> "$MD"

# Listening ports (labeled)
{
    echo "### Listening Ports"
    echo "| Port | Address | Process |"
    echo "|------|---------|---------|"
    ss -tlnp 2>/dev/null | awk 'NR>1{
        split($4, a, ":");
        port = a[length(a)];
        addr = substr($4, 1, length($4)-length(port)-1);
        proc = $6;
        gsub(/users:\(\("/, "", proc);
        gsub(/",pid=.*/, "", proc);
        if(port ~ /^[0-9]+$/ && port+0 < 50000)
            print "| " port " | " addr " | " proc " |"
    }' | sort -t'|' -k2 -n | uniq
    echo ""
} >> "$MD"

ss -tlnp 2>/dev/null | awk 'NR>1{
    split($4, a, ":");
    port = a[length(a)];
    addr = substr($4, 1, length($4)-length(port)-1);
    proc = $6;
    gsub(/users:\(\("/, "", proc);
    gsub(/",pid=.*/, "", proc);
    if(port ~ /^[0-9]+$/ && port+0 < 50000) {
        gsub(/"/, "\\\"", proc);
        print "[[network.ports]]"
        print "port = " port
        print "address = \"" addr "\""
        print "process = \"" proc "\""
        print ""
    }
}' >> "$TOML"

# ============================================================
# 4. APIS & MCPS
# ============================================================
{
    echo "## APIs & MCPs"
    echo ""
    echo "| Port | Service | Type | Endpoint |"
    echo "|------|---------|------|----------|"
} >> "$MD"

echo "[apis]" >> "$TOML"
echo "" >> "$TOML"

# Load catalog metadata for service enrichment
# Simple function to extract field from YAML
get_yaml_field() {
    local file=$1 field=$2
    # Extract value after colon, handling both quoted and unquoted values
    grep "^$field:" "$file" 2>/dev/null | sed 's/^[^:]*: *//; s/"//g' | head -1
}

# Type-to-slug mapping for discovered services
type_to_slug() {
    local type=$1 proc=$2
    case "$type" in
        "Ollama/LLM") echo "ollama" ;;
        "Vault") echo "hashicorp-vault" ;;
        "HTTP")
            # Try to infer from process name for generic HTTP services
            if [[ "$proc" =~ "ollama" ]]; then echo "ollama"
            elif [[ "$proc" =~ "chainlit" ]]; then echo "chainlit"
            elif [[ "$proc" =~ "fastapi\|starlette" ]]; then echo "fastapi"
            fi
            ;;
        *) echo "" ;;
    esac
}

# Look up catalog entry and extract enrichment data
enrich_service() {
    local slug=$1
    local catalog_dir="${PULSE_CATALOG_DIR:-$HOME/api-catalog/cards}"

    # Look for the YAML file in curated first, then other dirs
    for dir in curated public-apis apis-guru mcp-servers; do
        local yaml_file="$catalog_dir/$dir/$slug.yaml"
        if [ -f "$yaml_file" ]; then
            # Extract key fields
            local auth=$(get_yaml_field "$yaml_file" "auth:")
            local pricing=$(get_yaml_field "$yaml_file" "pricing")
            local open_source=$(get_yaml_field "$yaml_file" "open_source")
            local mcp_available=$(grep "^  available:" "$yaml_file" 2>/dev/null | awk '{print $2}' | head -1)

            # Output as TOML
            echo "catalog_slug = \"$slug\""
            [ -n "$pricing" ] && echo "pricing = \"$pricing\""
            [ -n "$open_source" ] && echo "open_source = $open_source"
            [ -n "$mcp_available" ] && echo "mcp_available = $mcp_available"
            return 0
        fi
    done

    return 1
}

# Probe listening ports for HTTP/JSON-RPC/MCP services
# Range: 1000-50000 captures application services while avoiding:
#   - Ports <1000: system services (SSH, DNS, etc.) - skip to reduce noise
#   - Ports >50000: ephemeral/temporary services - not of interest
# Each port gets probed with 1-second timeout to detect HTTP/Ollama/Vault/LocalAI
ss -tlnp 2>/dev/null | awk 'NR>1{
    split($4, a, ":");
    port = a[length(a)];
    if(port ~ /^[0-9]+$/ && port+0 > 1000 && port+0 < 50000) print port
}' | sort -n | while read -r port; do
    # Try to detect API type via HTTP probe
    # Note: This runs sequentially which can be slow if many ports are open.
    # For performance improvements with large port sets, use 'xargs -P N' for N parallel probes.
    api_type="unknown"
    endpoint=""

    # Try localhost first, then 127.0.0.1
    # 1-second timeout (-m1) per probe to avoid hanging on unresponsive services
    for addr in localhost 127.0.0.1; do
        # HTTP health/info endpoint
        info=$(curl -s -m1 "http://$addr:$port/health" 2>/dev/null || curl -s -m1 "http://$addr:$port/info" 2>/dev/null || true)
        if [ -n "$info" ]; then
            api_type="HTTP"
            endpoint="/health or /info"
            break
        fi

        # JSON-RPC (Ollama, LocalAI, etc.)
        info=$(curl -s -m1 -X POST "http://$addr:$port/api/tags" 2>/dev/null || true)
        if echo "$info" | grep -q "models\|tags"; then
            api_type="Ollama/LLM"
            endpoint="/api/tags"
            break
        fi

        # Vault API
        info=$(curl -s -m1 "http://$addr:$port/v1/sys/health" 2>/dev/null || true)
        if echo "$info" | grep -q "sealed\|initialized"; then
            api_type="Vault"
            endpoint="/v1/sys/health"
            break
        fi

        # LocalAI
        info=$(curl -s -m1 "http://$addr:$port/swagger.json" 2>/dev/null || true)
        if echo "$info" | grep -q "LocalAI\|openapi"; then
            api_type="LocalAI"
            endpoint="/swagger.json"
            break
        fi
    done

    # Get service name from netstat
    proc=$(ss -tlnp 2>/dev/null | awk -v p="$port" '$4 ~ ":" p "$" {print $6}' | head -1)
    if [ -z "$proc" ]; then
        proc="unknown"
    fi

    if [ "$api_type" != "unknown" ]; then
        echo "| $port | $proc | $api_type | $endpoint |" >> "$MD"

        # Escape proc and endpoint for TOML
        safe_proc=$(echo "$proc" | sed 's/\\/\\\\/g; s/"/\\"/g')
        safe_endpoint=$(echo "$endpoint" | sed 's/\\/\\\\/g; s/"/\\"/g')

        cat >> "$TOML" << EOF
[[apis.services]]
port = $port
process = "$safe_proc"
type = "$api_type"
endpoint = "$safe_endpoint"
EOF

        # Try to enrich with catalog metadata
        slug=$(type_to_slug "$api_type" "$safe_proc")
        if [ -n "$slug" ] && enrich_service "$slug" >> "$TOML"; then
            true
        fi

        echo "" >> "$TOML"
    fi
done

echo "" >> "$MD"

# ============================================================
# 5. ERRORS SINCE LAST PULSE
# ============================================================
{
    echo "## Errors Since Last Pulse"
    echo ""
} >> "$MD"
echo "[errors]" >> "$TOML"
echo "since = \"$LAST_PULSE\"" >> "$TOML"
echo "" >> "$TOML"

# Journalctl errors (deduplicated)
{
    errors=$(journalctl --since="$LAST_PULSE" -p err --no-pager -o cat 2>/dev/null | \
        grep -v '^\s*$\|Call Trace\|Code:\|dump_stack\|exc_page_fault\|asm_exc\|do_swap\|evict_folios\|folio_alloc\|__alloc_\|do_try_to_free\|do_user_addr\|cluster_alloc\|pages RAM\|pages reserved\|pages cma\|pages HighMem\|pages hwpoisoned\|total pagecache\|pages in swap\|active_anon\|active_file\|inactive_anon\|inactive_file\|isolated_anon\|isolated_file\|? asm_\|CPU:.*PID:.*Comm:' | \
        sort -u | head -50)
    if [ -n "$errors" ]; then
        echo '```'
        echo "$errors"
        echo '```'
    else
        echo "_No errors since last pulse._"
    fi
    echo ""

    # User journal errors
    user_errors=$(journalctl --user --since="$LAST_PULSE" -p err --no-pager -o cat 2>/dev/null | sort -u | head -50)
    if [ -n "$user_errors" ]; then
        echo "### User Service Errors"
        echo '```'
        echo "$user_errors"
        echo '```'
        echo ""
    fi

    # Docker container errors (unhealthy or restarting)
    if cmd_exists docker; then
        sick=$(docker ps -a --filter "status=restarting" --filter "health=unhealthy" --format '{{.Names}}: {{.Status}}' 2>/dev/null)
        if [ -n "$sick" ]; then
            echo "### Unhealthy/Restarting Containers"
            echo "$sick" | sed 's/^/- /'
            echo ""
        fi
    fi
} >> "$MD"

# Errors as TOML array
{
    journalctl --since="$LAST_PULSE" -p err --no-pager -o cat 2>/dev/null | \
        grep -v '^\s*$\|Call Trace\|Code:\|dump_stack\|exc_page_fault\|asm_exc\|do_swap\|evict_folios\|folio_alloc\|__alloc_\|do_try_to_free\|do_user_addr\|cluster_alloc\|pages RAM\|pages reserved\|pages cma\|pages HighMem\|pages hwpoisoned\|total pagecache\|pages in swap\|active_anon\|active_file\|inactive_anon\|inactive_file\|isolated_anon\|isolated_file\|? asm_\|CPU:.*PID:.*Comm:' | \
        sort -u | head -50 | while IFS= read -r line; do
        # Escape quotes and backslashes for TOML
        safe=$(echo "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "[[errors.journal]]"
        echo "message = \"$safe\""
        echo ""
    done

    journalctl --user --since="$LAST_PULSE" -p err --no-pager -o cat 2>/dev/null | sort -u | head -50 | while IFS= read -r line; do
        safe=$(echo "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "[[errors.journal_user]]"
        echo "message = \"$safe\""
        echo ""
    done
} >> "$TOML"

# ============================================================
# WRITE OUTPUT + ROTATE
# ============================================================
cp "$MD" "$MD_FILE"
cp "$TOML" "$TOML_FILE"

# Copy to KB if available
if [ -d "$KB_DIR" ]; then
    cp "$MD_FILE" "$KB_DIR/"
    cp "$TOML_FILE" "$KB_DIR/"
fi

# Rotate — keep only newest MAX_FILES of each type
rotate_dir() {
    local dir=$1
    [ -d "$dir" ] || return
    for ext in md toml; do
        local count
        count=$(ls -1 "$dir"/*."$ext" 2>/dev/null | wc -l)
        if [ "$count" -gt "$MAX_FILES" ]; then
            ls -1t "$dir"/*."$ext" | tail -n +"$((MAX_FILES + 1))" | xargs rm -f
        fi
    done
}

rotate_dir "$LOCAL_DIR"
rotate_dir "$KB_DIR"

echo "Pulse written: $MD_FILE"
echo "Pulse written: $TOML_FILE"
