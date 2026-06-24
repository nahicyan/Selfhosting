#!/bin/bash
# =============================================================================
# Debian VPN-Only Access Hardening Script v1
# =============================================================================
# Hardens a Debian host on OVH to be accessible only via WireGuard VPN,
# while keeping public ports open for web services and Jitsi ICE.
#
# Public surface (post-hardening):
#   - <wg_port>/udp  : WireGuard VPN entry point (world-open)
#   - 443/tcp        : HTTPS (Cloudflare IPs only, or world-open)
#   - 10000/udp      : Jitsi WebRTC ICE (world-open)
#
# VPN-gated (only reachable after connecting to WireGuard):
#   - 22/tcp         : SSH
#   - Everything else
#
# Features:
#   - Guided OVH hardware firewall setup (first line of defence)
#   - Systemd-based 120s rollback timer (survives SSH disconnects)
#   - Cloudflare IP-only restriction for port 443 (prevents origin bypass)
#   - nftables (Debian 13 native — not iptables, not UFW)
#   - IPv4 + IPv6 in a single inet table
#   - Atomic rule application via nft -f (all-or-nothing)
#   - Persistence via nftables.service + /etc/nftables.conf
#   - UFW conflict detection and removal
#
# Usage:
#   ./debian-vpn-hardening.sh           # Interactive setup wizard
#   ./debian-vpn-hardening.sh --apply   # Regenerate and apply saved config (for boot)
#   ./debian-vpn-hardening.sh --cancel  # Cancel pending rollback timer
#   ./debian-vpn-hardening.sh --status  # Show firewall and network status
#   ./debian-vpn-hardening.sh --restore # Restore last backup
#   ./debian-vpn-hardening.sh --refresh-cf  # Re-fetch Cloudflare IPs and reapply
#
# Boot integration (add to /etc/rc.local or a systemd unit):
#   /path/to/debian-vpn-hardening.sh --apply
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BACKUP_DIR="/root/firewall-backups"
CONFIG_FILE="/etc/debian-vpn-hardening.conf"
NFT_RULES_FILE="/etc/nftables.conf"
ROLLBACK_UNIT="fw-rollback"
ROLLBACK_TIMEOUT=120

# Cloudflare IP ranges — hardcoded fallback, refreshed via --refresh-cf
# Source: https://www.cloudflare.com/ips-v4 / ips-v6
CF_IPV4_HARDCODED=(
    173.245.48.0/20
    103.21.244.0/22
    103.22.200.0/22
    103.31.4.0/22
    141.101.64.0/18
    108.162.192.0/18
    190.93.240.0/20
    188.114.96.0/20
    197.234.240.0/22
    198.41.128.0/17
    162.158.0.0/15
    104.16.0.0/13
    104.24.0.0/14
    172.64.0.0/13
    131.0.72.0/22
)

CF_IPV6_HARDCODED=(
    2400:cb00::/32
    2606:4700::/32
    2803:f800::/32
    2405:b500::/32
    2405:8100::/32
    2a06:98c0::/29
    2c0f:f248::/32
)

# =============================================================================
# Logging
# =============================================================================

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${ORANGE}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${BLUE}[→]${NC} $1"; }

# =============================================================================
# Preflight Checks
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must be run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v nft   &>/dev/null || missing+=("nftables")
    command -v wg    &>/dev/null || missing+=("wireguard-tools")
    command -v curl  &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing packages: ${missing[*]}"
        read -rp "Install them now? [Y/n]: " inst
        inst=${inst:-Y}
        if [[ "$inst" =~ ^[Yy]$ ]]; then
            apt-get update -qq
            apt-get install -y "${missing[@]}"
        else
            log_error "Required packages missing. Exiting."
            exit 1
        fi
    fi
}

check_os() {
    if [[ ! -f /etc/debian_version ]]; then
        log_warn "This script is designed for Debian. Detected OS may differ."
        read -rp "Continue anyway? [y/N]: " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 1
    fi
}

check_ufw_conflict() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_warn "UFW is active and will conflict with nftables."
        echo ""
        echo "  UFW is a frontend that manages its own iptables/nftables rules."
        echo "  Running both will cause unpredictable firewall behaviour."
        echo ""
        read -rp "  Disable and remove UFW now? [Y/n]: " rm_ufw
        rm_ufw=${rm_ufw:-Y}
        if [[ "$rm_ufw" =~ ^[Yy]$ ]]; then
            ufw disable 2>/dev/null || true
            apt-get remove -y ufw > /dev/null 2>&1 || true
            log_info "UFW removed."
        else
            log_warn "Keeping UFW. Rules may conflict — proceed with caution."
        fi
    fi
}

# =============================================================================
# WireGuard Detection
# =============================================================================

# Outputs "NIC:PORT" or "" if not found
detect_wireguard() {
    # Method 1: wireguard-install.sh params file
    if [[ -f /etc/wireguard/params ]]; then
        # shellcheck source=/dev/null
        source /etc/wireguard/params
        if [[ -n "${SERVER_WG_NIC:-}" && -n "${SERVER_PORT:-}" ]]; then
            echo "${SERVER_WG_NIC}:${SERVER_PORT}"
            return
        fi
    fi

    # Method 2: scan /etc/wireguard/*.conf
    for conf in /etc/wireguard/*.conf; do
        [[ -f "$conf" ]] || continue
        local nic port
        nic=$(basename "$conf" .conf)
        port=$(grep -iP '^\s*ListenPort\s*=' "$conf" 2>/dev/null | grep -oP '\d+' | head -1)
        if [[ -n "$port" ]]; then
            echo "${nic}:${port}"
            return
        fi
    done

    # Method 3: wg show (if a tunnel is already up)
    if command -v wg &>/dev/null; then
        local nic port
        nic=$(wg show interfaces 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -n "$nic" ]]; then
            port=$(wg show "$nic" listen-port 2>/dev/null || true)
            if [[ -n "$port" ]]; then
                echo "${nic}:${port}"
                return
            fi
        fi
    fi

    echo ""
}

detect_wan_interface() {
    ip -4 route show default 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
        | head -1
}

# Returns the WireGuard subnet this host is in, e.g. "10.66.66.0/24"
detect_wg_subnet() {
    local wg_nic="$1"
    ip -4 route show dev "$wg_nic" scope link 2>/dev/null | awk '{print $1}' | head -1
}

# Checks whether the current SSH client IP is inside the WireGuard subnet
check_connected_via_vpn() {
    local wg_nic="$1"
    local client_ip="${SSH_CLIENT%% *}"

    [[ -z "$client_ip" ]] && return 1

    local wg_subnet
    wg_subnet=$(detect_wg_subnet "$wg_nic")

    [[ -z "$wg_subnet" ]] && return 1

    python3 -c "
import ipaddress, sys
try:
    net = ipaddress.ip_network('${wg_subnet}', strict=False)
    ip  = ipaddress.ip_address('${client_ip}')
    sys.exit(0 if ip in net else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# =============================================================================
# OVH Hardware Firewall Guide
# =============================================================================

show_ovh_guide() {
    local wg_port="$1"

    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║            STEP 1 — OVH Hardware Firewall Setup                   ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  The OVH hardware firewall sits in front of your server at the network"
    echo "  level — it stops traffic before it even reaches your NIC. Configure"
    echo "  it first so you have a fallback if the host firewall misbehaves."
    echo ""
    echo -e "  ${CYAN}Where:${NC}"
    echo "    OVH Control Panel → Bare Metal Cloud → IP → ⚙ → Firewall"
    echo "    (Enable the firewall for your server's IP if not already on)"
    echo ""
    echo -e "  ${CYAN}Rules to add (in order):${NC}"
    echo ""
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "Pri" "Action" "Protocol" "Source" "Dest Port" "Purpose"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "---" "------" "--------" "------" "---------" "-------"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "0"   "PERMIT" "TCP"      "any"    "established" "Return traffic (stateful)"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "1"   "PERMIT" "UDP"      "any"    "${wg_port}"  "WireGuard VPN"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "2"   "PERMIT" "TCP"      "any"    "443"         "HTTPS"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "3"   "PERMIT" "UDP"      "any"    "10000"       "Jitsi ICE / WebRTC"
    printf "  %-4s %-8s %-10s %-10s %-12s %s\n" "19"  "DENY"   "any"      "any"    "any"         "Block everything else"
    echo ""
    echo -e "  ${ORANGE}Note:${NC} OVH's firewall uses priority 19 as the final catch-all deny."
    echo "  You do NOT need to add a rule for SSH (port 22) — it will be"
    echo "  VPN-gated by this script, so the hardware firewall blocks it too."
    echo ""
}

# =============================================================================
# Backup / Restore
# =============================================================================

backup_rules() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR"

    local backup_file="$BACKUP_DIR/nftables.$timestamp.nft"

    log_step "Backing up current nftables rules..."
    { echo "flush ruleset"; nft list ruleset 2>/dev/null; } > "$backup_file" || true
    ln -sf "$backup_file" "$BACKUP_DIR/nftables.latest.nft"
    log_info "Backup saved: $backup_file"
}

restore_backup() {
    local backup="$BACKUP_DIR/nftables.latest.nft"
    if [[ ! -f "$backup" ]]; then
        log_error "No backup found at $backup"
        return 1
    fi

    log_step "Restoring rules from $backup..."
    nft -f "$backup"
    log_info "Backup restored."
}

# =============================================================================
# Rollback Mechanism (systemd-based — survives SSH disconnects)
# =============================================================================

schedule_rollback() {
    local timeout="$1"

    cancel_rollback 2>/dev/null || true

    log_warn "Scheduling automatic rollback in ${timeout}s via systemd..."
    log_warn "Run '$0 --cancel' to make rules permanent after confirming access."

    local backup="$BACKUP_DIR/nftables.latest.nft"

    systemd-run \
        --unit="${ROLLBACK_UNIT}" \
        --on-active="${timeout}s" \
        --service-type=oneshot \
        --description="nftables rollback safety timer" \
        /bin/bash -c "
            echo 'ROLLBACK: Timeout reached — restoring previous rules...' >&2
            if [[ -f '${backup}' ]]; then
                nft -f '${backup}' 2>/dev/null && echo 'ROLLBACK: Done.' >&2 || echo 'ROLLBACK: nft restore failed!' >&2
            else
                echo 'ROLLBACK: No backup found — flushing to open state for safety.' >&2
                nft flush ruleset 2>/dev/null || true
            fi
        " 2>/dev/null || {
        log_error "Failed to schedule systemd rollback timer."
        return 1
    }

    log_info "Rollback timer armed (survives SSH disconnects via systemd)"
}

cancel_rollback() {
    local cancelled=false

    if systemctl is-active --quiet "${ROLLBACK_UNIT}.timer" 2>/dev/null; then
        systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
        cancelled=true
    fi
    if systemctl is-active --quiet "${ROLLBACK_UNIT}.service" 2>/dev/null; then
        systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true
        cancelled=true
    fi

    systemctl reset-failed "${ROLLBACK_UNIT}.timer"   2>/dev/null || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true

    if $cancelled; then
        log_info "Rollback cancelled — rules are now permanent."
    else
        log_info "No pending rollback found."
    fi
}

is_rollback_pending() {
    systemctl is-active --quiet "${ROLLBACK_UNIT}.timer" 2>/dev/null
}

# =============================================================================
# Cloudflare IP Management
# =============================================================================

# Tries to fetch current Cloudflare IPs from their API.
# Returns 0 on success and populates CF_IPV4_LIVE / CF_IPV6_LIVE arrays.
fetch_cloudflare_ips() {
    log_step "Fetching current Cloudflare IP ranges..."

    local v4 v6
    v4=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null || true)
    v6=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" 2>/dev/null || true)

    if [[ -n "$v4" && -n "$v6" ]]; then
        mapfile -t CF_IPV4_LIVE <<< "$v4"
        mapfile -t CF_IPV6_LIVE <<< "$v6"
        log_info "Fetched live Cloudflare IPs (${#CF_IPV4_LIVE[@]} IPv4, ${#CF_IPV6_LIVE[@]} IPv6)"
        return 0
    fi

    log_warn "Could not reach Cloudflare API — using hardcoded fallback ranges."
    CF_IPV4_LIVE=("${CF_IPV4_HARDCODED[@]}")
    CF_IPV6_LIVE=("${CF_IPV6_HARDCODED[@]}")
    return 1
}

# Formats array elements as a comma-separated nftables set element list
format_nft_set() {
    local -n arr="$1"
    local result=""
    for elem in "${arr[@]}"; do
        elem=$(echo "$elem" | tr -d '[:space:]')
        [[ -z "$elem" ]] && continue
        result="${result}${elem}, "
    done
    echo "${result%, }"  # strip trailing comma+space
}

# =============================================================================
# Configuration Persistence
# =============================================================================

save_config() {
    local wg_nic="$1"
    local wg_port="$2"
    local cloudflare_restrict="$3"
    local jitsi_port="${4:-10000}"

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# debian-vpn-hardening configuration
# Generated: $(date)
WG_NIC=${wg_nic}
WG_PORT=${wg_port}
CLOUDFLARE_RESTRICT=${cloudflare_restrict}
JITSI_PORT=${jitsi_port}
EOF
    log_info "Config saved to $CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# =============================================================================
# nftables Rule Generation
# =============================================================================

# Generates a complete nftables ruleset as a string.
# Call with:
#   generate_ruleset WG_NIC WG_PORT WAN_IF CLOUDFLARE_RESTRICT JITSI_PORT
#   where CLOUDFLARE_RESTRICT = "true" | "false"
generate_ruleset() {
    local wg_nic="$1"
    local wg_port="$2"
    local cloudflare_restrict="$3"
    local jitsi_port="${4:-10000}"

    # Build 443 rule depending on Cloudflare restriction
    local https_rule_v4 https_rule_v6
    if [[ "$cloudflare_restrict" == "true" ]]; then
        https_rule_v4='        tcp dport 443 ip  saddr @cf_ipv4 accept comment "HTTPS via Cloudflare (IPv4)"'
        https_rule_v6='        tcp dport 443 ip6 saddr @cf_ipv6 accept comment "HTTPS via Cloudflare (IPv6)"'
    else
        https_rule_v4='        tcp dport 443 accept comment "HTTPS (world-open)"'
        https_rule_v6=''
    fi

    # Format Cloudflare sets (only needed if restricting)
    local cf_v4_set="" cf_v6_set=""
    if [[ "$cloudflare_restrict" == "true" ]]; then
        fetch_cloudflare_ips
        local cf_v4_elems cf_v6_elems
        cf_v4_elems=$(format_nft_set CF_IPV4_LIVE)
        cf_v6_elems=$(format_nft_set CF_IPV6_LIVE)

        cf_v4_set="
    set cf_ipv4 {
        type ipv4_addr
        flags interval
        elements = { ${cf_v4_elems} }
    }"

        cf_v6_set="
    set cf_ipv6 {
        type ipv6_addr
        flags interval
        elements = { ${cf_v6_elems} }
    }"
    fi

    cat << RULESET
#!/usr/sbin/nft -f
# =============================================================================
# nftables ruleset — generated by debian-vpn-hardening.sh
# $(date)
# WireGuard: ${wg_nic} port ${wg_port}/udp
# Cloudflare restriction on 443: ${cloudflare_restrict}
# Jitsi ICE port: ${jitsi_port}/udp
# =============================================================================

flush ruleset

table inet filter {
${cf_v4_set}
${cf_v6_set}

    chain input {
        type filter hook input priority filter; policy drop;

        # Loopback — always allow
        iif "lo" accept

        # Drop invalid connection states immediately
        ct state invalid drop

        # Allow established and related (return traffic)
        ct state { established, related } accept

        # ICMPv4 — allow useful types (ping, unreachable, TTL exceeded)
        ip protocol icmp icmp type {
            echo-request, echo-reply,
            destination-unreachable, time-exceeded, parameter-problem
        } accept

        # ICMPv6 — required for IPv6 neighbour discovery and path MTU
        ip6 nexthdr icmpv6 icmpv6 type {
            echo-request, echo-reply,
            destination-unreachable, packet-too-big,
            time-exceeded, parameter-problem,
            nd-router-solicit, nd-router-advert,
            nd-neighbor-solicit, nd-neighbor-advert
        } accept

        # WireGuard UDP — world-open (this is the only admin entry point)
        udp dport ${wg_port} accept comment "WireGuard VPN"

        # HTTPS — Cloudflare-restricted or world-open
${https_rule_v4}
${https_rule_v6}

        # Jitsi WebRTC ICE — world-open (UDP media relay)
        udp dport ${jitsi_port} accept comment "Jitsi ICE / WebRTC"

        # WireGuard tunnel interface — full unrestricted access
        # (SSH, all management ports, everything lives here)
        iif "${wg_nic}" accept comment "WireGuard clients — trusted"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        # No forwarding — this is a single-host server, not a router
    }

    chain output {
        type filter hook output priority filter; policy accept;
        # Outbound is unrestricted
    }
}
RULESET
}

# =============================================================================
# Apply and Save
# =============================================================================

apply_ruleset() {
    local ruleset="$1"
    local tmp
    tmp=$(mktemp /tmp/nft-rules-XXXXXX.nft)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    echo "$ruleset" > "$tmp"

    log_step "Applying nftables rules atomically..."
    nft -f "$tmp"
    log_info "Rules applied."
}

persist_ruleset() {
    local ruleset="$1"

    log_step "Writing rules to $NFT_RULES_FILE..."
    echo "$ruleset" > "$NFT_RULES_FILE"

    log_step "Enabling nftables.service for boot persistence..."
    systemctl enable nftables > /dev/null 2>&1 || true

    # Tell nftables.service to reload from the file we just wrote
    # (doesn't fail if service isn't running yet)
    systemctl reload-or-restart nftables > /dev/null 2>&1 || true

    log_info "Rules persisted to $NFT_RULES_FILE (loaded at boot via nftables.service)"
}

# =============================================================================
# Status
# =============================================================================

show_status() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                   Firewall Status                             ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}Network:${NC}"
    local wan
    wan=$(detect_wan_interface)
    echo "  WAN interface : ${wan:-unknown}"

    if [[ -n "$(detect_wireguard)" ]]; then
        local wg_pair
        wg_pair=$(detect_wireguard)
        local wg_nic="${wg_pair%%:*}"
        local wg_port="${wg_pair##*:}"
        echo "  WireGuard     : ${wg_nic} port ${wg_port}/udp"
        if ip link show "$wg_nic" &>/dev/null; then
            local wg_peers
            wg_peers=$(wg show "$wg_nic" peers 2>/dev/null | wc -l)
            echo "  WG status     : UP (${wg_peers} peer(s))"
        else
            echo -e "  WG status     : ${RED}DOWN${NC}"
        fi
    else
        echo -e "  WireGuard     : ${RED}not detected${NC}"
    fi
    echo ""

    echo -e "${CYAN}nftables:${NC}"
    if nft list tables 2>/dev/null | grep -q "inet filter"; then
        echo -e "  Ruleset       : ${GREEN}loaded${NC}"
        local chain_policy
        chain_policy=$(nft list chain inet filter input 2>/dev/null | grep -oP 'policy \K\w+')
        echo "  INPUT policy  : ${chain_policy:-unknown}"
    else
        echo -e "  Ruleset       : ${ORANGE}no inet filter table${NC}"
    fi
    if [[ -f "$NFT_RULES_FILE" ]]; then
        echo -e "  Persistence   : ${GREEN}$NFT_RULES_FILE exists${NC}"
    else
        echo -e "  Persistence   : ${RED}$NFT_RULES_FILE missing — rules won't survive reboot${NC}"
    fi
    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        echo -e "  Boot service  : ${GREEN}enabled${NC}"
    else
        echo -e "  Boot service  : ${RED}disabled${NC}"
    fi
    echo ""

    echo -e "${CYAN}Saved config ($CONFIG_FILE):${NC}"
    if load_config 2>/dev/null; then
        echo "  WG interface  : ${WG_NIC:-unset}"
        echo "  WG port       : ${WG_PORT:-unset}"
        echo "  CF restrict   : ${CLOUDFLARE_RESTRICT:-unset}"
        echo "  Jitsi port    : ${JITSI_PORT:-10000}"
    else
        echo -e "  ${ORANGE}No saved config — run interactive setup first.${NC}"
    fi
    echo ""

    echo -e "${CYAN}Rollback timer:${NC}"
    if is_rollback_pending; then
        echo -e "  ${ORANGE}PENDING — run '$0 --cancel' to make rules permanent${NC}"
    else
        echo "  None"
    fi
    echo ""

    echo -e "${CYAN}Live ruleset summary:${NC}"
    nft list ruleset 2>/dev/null | grep -E '(table|chain|policy|dport|saddr|iif|comment)' \
        | sed 's/^/  /' || echo "  (could not list ruleset)"
    echo ""
}

# =============================================================================
# Interactive Setup Wizard
# =============================================================================

interactive_setup() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║        Debian VPN-Only Hardening — Setup Wizard v1            ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"

    # ── 0. Preflight ──────────────────────────────────────────────────────────
    check_os
    check_dependencies
    check_ufw_conflict

    # ── 1. Detect WireGuard ───────────────────────────────────────────────────
    echo ""
    local wg_pair
    wg_pair=$(detect_wireguard)

    local wg_nic wg_port
    if [[ -n "$wg_pair" ]]; then
        wg_nic="${wg_pair%%:*}"
        wg_port="${wg_pair##*:}"
        log_info "WireGuard detected: interface ${wg_nic}, port ${wg_port}/udp"
    else
        log_warn "WireGuard not detected automatically."
        echo ""
        echo "  Install WireGuard first (e.g. via wireguard-install.sh),"
        echo "  then re-run this script."
        echo ""
        read -rp "  Enter WireGuard interface manually (e.g. wg0), or blank to exit: " wg_nic
        [[ -z "$wg_nic" ]] && { echo "Exiting."; exit 0; }
        read -rp "  Enter WireGuard listen port: " wg_port
        if [[ ! "$wg_port" =~ ^[0-9]+$ ]]; then
            log_error "Invalid port. Exiting."; exit 1
        fi
    fi

    # ── 2. OVH hardware firewall guide ────────────────────────────────────────
    show_ovh_guide "$wg_port"

    read -rp "Have you configured the OVH hardware firewall as shown above? [y/N]: " ovh_done
    if [[ ! "$ovh_done" =~ ^[Yy]$ ]]; then
        echo ""
        log_warn "Please set up the OVH firewall first — it's your outer safety net."
        echo "  You can re-run this script afterwards."
        exit 0
    fi

    # ── 3. Cloudflare restriction for 443 ─────────────────────────────────────
    echo ""
    echo -e "${CYAN}Port 443 — Cloudflare restriction${NC}"
    echo ""
    echo "  If your domain is proxied through Cloudflare, restricting port 443"
    echo "  to Cloudflare IP ranges prevents attackers from bypassing Cloudflare"
    echo "  and hitting your origin directly."
    echo ""
    read -rp "  Restrict port 443 to Cloudflare IPs only? [Y/n]: " cf_choice
    cf_choice=${cf_choice:-Y}
    local cloudflare_restrict="false"
    [[ "$cf_choice" =~ ^[Yy]$ ]] && cloudflare_restrict="true"

    # ── 4. Jitsi port ─────────────────────────────────────────────────────────
    echo ""
    read -rp "Jitsi ICE port [default: 10000]: " jitsi_port
    jitsi_port=${jitsi_port:-10000}
    if [[ ! "$jitsi_port" =~ ^[0-9]+$ ]]; then
        log_error "Invalid port."; exit 1
    fi

    # ── 5. VPN connection check ───────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}VPN connection verification${NC}"
    echo ""
    if check_connected_via_vpn "$wg_nic"; then
        log_info "Detected: you are currently connected via WireGuard. Good."
    else
        log_warn "Your current session does not appear to be over WireGuard."
        echo ""
        echo "  After hardening, only WireGuard clients can SSH in."
        echo "  If you apply now without a VPN connection, you will be locked out."
        echo "  The ${ROLLBACK_TIMEOUT}s rollback timer is your safety net — but"
        echo "  it is strongly recommended to connect via WireGuard FIRST."
        echo ""
    fi

    # ── 6. Generate and preview ruleset ──────────────────────────────────────
    echo ""
    log_step "Generating nftables ruleset..."
    local ruleset
    ruleset=$(generate_ruleset "$wg_nic" "$wg_port" "$cloudflare_restrict" "$jitsi_port")

    echo ""
    echo "=== Generated ruleset ==="
    echo "$ruleset"
    echo "========================="
    echo ""

    # ── 7. Final confirmation ─────────────────────────────────────────────────
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: Applying this will block all non-VPN access!         ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  Allowed public ports after hardening:                         ║${NC}"
    echo -e "${RED}║    ${wg_port}/udp  — WireGuard (your VPN entry point)${NC}"
    echo -e "${RED}║    443/tcp      — HTTPS (Cloudflare only: ${cloudflare_restrict})${NC}"
    echo -e "${RED}║    ${jitsi_port}/udp  — Jitsi ICE / WebRTC${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  A ${ROLLBACK_TIMEOUT}s systemd rollback timer will be armed.              ║${NC}"
    echo -e "${RED}║  Test in a NEW terminal, then run:  $0 --cancel   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Apply rules with ${ROLLBACK_TIMEOUT}s auto-rollback? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    # ── 8. Apply ──────────────────────────────────────────────────────────────
    backup_rules
    schedule_rollback "$ROLLBACK_TIMEOUT"
    apply_ruleset "$ruleset"

    echo ""
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Rules applied. You have ${ROLLBACK_TIMEOUT}s before auto-rollback.${NC}"
    echo -e "${GREEN}  Open a NEW terminal and verify:${NC}"
    echo -e "${GREEN}    1. WireGuard VPN connects${NC}"
    echo -e "${GREEN}    2. SSH works through the VPN${NC}"
    echo -e "${GREEN}    3. Direct SSH (without VPN) is blocked${NC}"
    echo -e "${GREEN}  Then run:  $0 --cancel${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo ""

    read -rp "Verified access? Confirm, cancel rollback and persist? [y/N]: " verified
    if [[ "$verified" =~ ^[Yy]$ ]]; then
        cancel_rollback
        save_config "$wg_nic" "$wg_port" "$cloudflare_restrict" "$jitsi_port"
        persist_ruleset "$ruleset"

        echo ""
        log_info "Hardening complete."
        echo ""
        echo "  Summary:"
        echo "    WireGuard port ${wg_port}/udp  — open to internet"
        echo "    443/tcp                        — Cloudflare-restricted: ${cloudflare_restrict}"
        echo "    ${jitsi_port}/udp                      — Jitsi ICE open to internet"
        echo "    Everything else                — VPN-gated"
        echo ""
        echo "  To add or change rules, edit /etc/nftables.conf directly,"
        echo "  then run:  systemctl reload nftables"
        echo ""
        echo "  To re-run with updated Cloudflare IPs:  $0 --refresh-cf"
    else
        log_warn "Rules NOT persisted. Rollback will fire in ~${ROLLBACK_TIMEOUT}s."
    fi
}

# =============================================================================
# --apply  (boot-time / non-interactive regeneration)
# =============================================================================

apply_from_config() {
    if ! load_config; then
        log_error "No saved config found at $CONFIG_FILE"
        log_error "Run interactive setup first: $0"
        exit 1
    fi

    log_step "Regenerating ruleset from saved config..."
    local ruleset
    ruleset=$(generate_ruleset "${WG_NIC}" "${WG_PORT}" "${CLOUDFLARE_RESTRICT}" "${JITSI_PORT:-10000}")
    apply_ruleset "$ruleset"
    log_info "Rules applied from saved config (WG: ${WG_NIC}:${WG_PORT})"
}

# =============================================================================
# --refresh-cf  (re-fetch Cloudflare IPs and reapply)
# =============================================================================

refresh_cloudflare() {
    if ! load_config; then
        log_error "No saved config at $CONFIG_FILE — run interactive setup first."
        exit 1
    fi

    if [[ "${CLOUDFLARE_RESTRICT}" != "true" ]]; then
        log_warn "Cloudflare restriction is not enabled in your config. Nothing to refresh."
        exit 0
    fi

    log_step "Refreshing Cloudflare IPs and reapplying rules..."
    backup_rules
    local ruleset
    ruleset=$(generate_ruleset "${WG_NIC}" "${WG_PORT}" "true" "${JITSI_PORT:-10000}")
    apply_ruleset "$ruleset"
    persist_ruleset "$ruleset"
    log_info "Cloudflare IPs refreshed and rules reapplied."
}

# =============================================================================
# Main
# =============================================================================

check_root

case "${1:-}" in
    --apply)
        apply_from_config
        ;;
    --cancel)
        cancel_rollback
        ;;
    --status)
        show_status
        ;;
    --restore)
        restore_backup
        ;;
    --refresh-cf)
        refresh_cloudflare
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "  (none)        Interactive setup wizard"
        echo "  --apply       Apply rules from saved config (use at boot)"
        echo "  --cancel      Cancel pending rollback timer"
        echo "  --status      Show firewall and WireGuard status"
        echo "  --restore     Restore last backup"
        echo "  --refresh-cf  Re-fetch Cloudflare IPs and reapply"
        echo "  --help        This help text"
        ;;
    "")
        interactive_setup
        ;;
    *)
        log_error "Unknown option: $1"
        exit 1
        ;;
esac
