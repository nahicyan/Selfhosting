#!/bin/bash
# =============================================================================
# Proxmox VPN-Only Access Hardening Script v5
# =============================================================================
# This script hardens a Proxmox host to be accessible only via WireGuard VPN
# while preserving VM networking and providing safe remote application.
#
# Features:
#   - Automatic rollback via systemd (survives SSH disconnects!)
#   - IPv4 AND IPv6 hardening
#   - Preserves VM bridge forwarding and NAT
#   - Proper CIDR detection (no /24 assumptions)
#   - Custom rules support for port forwards with validation
#   - MSS clamping for MTU issues
#   - Boot-order safe (regenerates from custom.d on apply)
#   - Atomic rule application via iptables-restore
#
# Usage:
#   ./proxmox-vpn-hardening.sh           # Interactive mode
#   ./proxmox-vpn-hardening.sh --apply   # Regenerate and apply rules (for boot)
#   ./proxmox-vpn-hardening.sh --cancel  # Cancel pending rollback
#   ./proxmox-vpn-hardening.sh --status  # Show current firewall status
#   ./proxmox-vpn-hardening.sh --restore # Restore last backup
#   ./proxmox-vpn-hardening.sh --save    # Save current rules for persistence
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
BACKUP_DIR="/root/firewall-backups"
RULES_DIR="/etc/iptables"
CUSTOM_DIR="/etc/iptables/custom.d"
CONFIG_FILE="/etc/iptables/vpn-hardening.conf"
ROLLBACK_TIMEOUT=120  # seconds
ROLLBACK_UNIT="fw-rollback"

# Track if user chose to keep Proxmox firewall
KEEP_PVE_FIREWALL=false

# =============================================================================
# Helper Functions
# =============================================================================

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${ORANGE}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_wireguard() {
    if [[ ! -e /etc/wireguard/params ]]; then
        log_error "WireGuard not installed or configured."
        echo "Please install WireGuard first using the wireguard-install.sh script."
        exit 1
    fi
}

backup_current_rules() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR"
    
    log_step "Backing up current iptables rules..."
    iptables-save > "$BACKUP_DIR/rules.v4.$timestamp" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/rules.v6.$timestamp" 2>/dev/null || true
    
    ln -sf "$BACKUP_DIR/rules.v4.$timestamp" "$BACKUP_DIR/rules.v4.latest"
    ln -sf "$BACKUP_DIR/rules.v6.$timestamp" "$BACKUP_DIR/rules.v6.latest"
    
    log_info "Backup saved to $BACKUP_DIR/*.$timestamp"
}

restore_backup() {
    if [[ -f "$BACKUP_DIR/rules.v4.latest" ]]; then
        log_step "Restoring IPv4 rules from backup..."
        iptables-restore -w < "$BACKUP_DIR/rules.v4.latest"
    fi
    if [[ -f "$BACKUP_DIR/rules.v6.latest" ]]; then
        log_step "Restoring IPv6 rules from backup..."
        ip6tables-restore -w < "$BACKUP_DIR/rules.v6.latest"
    fi
    log_info "Backup restored."
}

# =============================================================================
# Rollback Mechanism (systemd-based - survives SSH disconnects)
# =============================================================================

schedule_rollback() {
    local timeout="$1"
    
    # Cancel any existing rollback first
    cancel_rollback 2>/dev/null || true
    
    log_warn "Scheduling automatic rollback in ${timeout}s via systemd..."
    log_warn "Run '$0 --cancel' to cancel rollback after confirming access."
    
    # Use systemd-run with a transient timer - this survives SSH disconnects
    systemd-run \
        --unit="${ROLLBACK_UNIT}" \
        --on-active="${timeout}s" \
        --service-type=oneshot \
        --description="Firewall rollback safety timer" \
        /bin/bash -c "
            echo 'ROLLBACK: Timeout reached, restoring previous rules...' >&2
            if [[ -f '$BACKUP_DIR/rules.v4.latest' ]]; then
                iptables-restore -w < '$BACKUP_DIR/rules.v4.latest' 2>/dev/null || true
            fi
            if [[ -f '$BACKUP_DIR/rules.v6.latest' ]]; then
                ip6tables-restore -w < '$BACKUP_DIR/rules.v6.latest' 2>/dev/null || true
            fi
            echo 'ROLLBACK: Previous rules restored.' >&2
        " 2>/dev/null || {
        log_error "Failed to schedule systemd rollback timer"
        return 1
    }
    
    log_info "Rollback timer scheduled (survives SSH disconnects)"
}

cancel_rollback() {
    local cancelled=false
    
    # Stop and clean up both timer and service
    if systemctl is-active --quiet "${ROLLBACK_UNIT}.timer" 2>/dev/null; then
        systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
        cancelled=true
    fi
    
    if systemctl is-active --quiet "${ROLLBACK_UNIT}.service" 2>/dev/null; then
        systemctl stop "${ROLLBACK_UNIT}.service" 2>/dev/null || true
        cancelled=true
    fi
    
    # Reset failed state if any
    systemctl reset-failed "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
    
    if $cancelled; then
        log_info "Rollback cancelled. Rules are now permanent."
    else
        log_info "No pending rollback found."
    fi
}

is_rollback_pending() {
    systemctl is-active --quiet "${ROLLBACK_UNIT}.timer" 2>/dev/null
}

# =============================================================================
# Detection Functions
# =============================================================================

detect_proxmox_firewall() {
    local pve_fw_active=false
    local nft_fw_active=false
    
    if systemctl is-active --quiet pve-firewall 2>/dev/null; then
        pve_fw_active=true
    fi
    if systemctl is-active --quiet proxmox-firewall 2>/dev/null; then
        nft_fw_active=true
    fi
    
    if $nft_fw_active; then
        echo "nftables"
    elif $pve_fw_active; then
        echo "iptables-pve"
    else
        echo "none"
    fi
}

detect_wan_interface() {
    ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

# Get WireGuard subnet - returns "network|is_32" format
# Examples: "10.66.66.0/24|false" or "|true" (for /32) or "|false" (detection failed)
detect_wg_network() {
    local wg_nic="$1"
    
    # Best case: get connected route directly from kernel
    local net
    net=$(ip -4 route show dev "$wg_nic" scope link 2>/dev/null | awk '{print $1}' | head -1)
    
    if [[ -n "$net" && "$net" != */32 ]]; then
        echo "${net}|false"
        return
    fi
    
    # Fallback: derive from interface address
    local cidr
    cidr=$(ip -o -4 addr show dev "$wg_nic" 2>/dev/null | awk '{print $4}' | head -1)
    
    if [[ -z "$cidr" ]]; then
        # No address found - detection failed
        echo "|false"
        return
    fi
    
    # Check for /32 - will need interface-based NAT fallback
    if [[ "$cidr" == */32 ]]; then
        echo "|true"
        return
    fi
    
    # Calculate network from CIDR using bash arithmetic
    local ip_addr="${cidr%/*}"
    local prefix="${cidr#*/}"
    
    local IFS='.'
    read -r a b c d <<< "$ip_addr"
    
    local mask=$(( 0xFFFFFFFF << (32 - prefix) ))
    local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
    local net_int=$(( ip_int & mask ))
    
    local net_a=$(( (net_int >> 24) & 255 ))
    local net_b=$(( (net_int >> 16) & 255 ))
    local net_c=$(( (net_int >> 8) & 255 ))
    local net_d=$(( net_int & 255 ))
    
    echo "${net_a}.${net_b}.${net_c}.${net_d}/${prefix}|false"
}

detect_bridges() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
}

get_bridge_network() {
    local br="$1"
    ip -4 route show dev "$br" scope link 2>/dev/null | awk '{print $1}' | head -1
}

# Categorize bridges and warn about those without IPs
categorize_bridges() {
    local wan_if=$(detect_wan_interface)
    local bridges=$(detect_bridges)
    
    local lan_bridges=""
    local wan_bridge=""
    
    for br in $bridges; do
        if [[ "$br" == "$wan_if" ]]; then
            wan_bridge="$br"
        else
            local net=$(get_bridge_network "$br")
            if [[ -n "$net" ]]; then
                if [[ "$net" =~ ^10\. ]] || [[ "$net" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || [[ "$net" =~ ^192\.168\. ]]; then
                    lan_bridges="$lan_bridges $br"
                fi
            else
                # Bridge exists but has no IP - warn user
                log_warn "Bridge $br has no host IP/subnet - will NOT be NATed automatically"
            fi
        fi
    done
    
    echo "WAN:$wan_bridge"
    echo "LAN:$lan_bridges"
}

# =============================================================================
# Custom Rules Support with Validation
# =============================================================================

setup_custom_dirs() {
    mkdir -p "$CUSTOM_DIR"
    
    if [[ ! -f "$CUSTOM_DIR/filter.rules" ]]; then
        cat > "$CUSTOM_DIR/filter.rules" << 'EOF'
# Custom filter rules - add your own rules here
# These will be included in the filter table
#
# IMPORTANT: If you add DNAT rules in nat.rules, you MUST add matching
# FORWARD rules here to allow the traffic!
#
# Example - to allow port 69696 forwarded to 192.168.1.10:
#   -A FORWARD -i vmbr0 -o vmbr1 -p tcp -d 192.168.1.10 --dport 69696 -m conntrack --ctstate NEW -j ACCEPT
EOF
    fi
    
    if [[ ! -f "$CUSTOM_DIR/nat.rules" ]]; then
        cat > "$CUSTOM_DIR/nat.rules" << 'EOF'
# Custom NAT rules - add your port forwards here
# These will be included in the nat table
#
# IMPORTANT: DNAT rules alone are NOT enough! You must also add a matching
# FORWARD rule in filter.rules to allow the traffic.
#
# Example - to forward public port 69696 to VM 192.168.1.10:
#   In this file (nat.rules):
#     -A PREROUTING -i vmbr0 -p tcp --dport 69696 -j DNAT --to-destination 192.168.1.10:69696
#
#   In filter.rules:
#     -A FORWARD -i vmbr0 -o vmbr1 -p tcp -d 192.168.1.10 --dport 69696 -m conntrack --ctstate NEW -j ACCEPT
EOF
    fi
    
    if [[ ! -f "$CUSTOM_DIR/mangle.rules" ]]; then
        cat > "$CUSTOM_DIR/mangle.rules" << 'EOF'
# Custom mangle rules
# These will be included in the mangle table
EOF
    fi
}

get_custom_rules() {
    local table="$1"
    local file="$CUSTOM_DIR/${table}.rules"
    
    if [[ -f "$file" ]]; then
        grep -v '^\s*#' "$file" 2>/dev/null | grep -v '^\s*$' || true
    fi
}

# Validate custom rules - uses process substitution, always returns 0
validate_custom_rules() {
    local nat_rules=$(get_custom_rules "nat")
    local filter_rules=$(get_custom_rules "filter")
    local warnings=0
    
    if [[ -z "$nat_rules" ]]; then
        echo "  - No custom DNAT rules configured"
        return 0
    fi
    
    # Use process substitution to avoid subshell variable scoping issue
    while read -r rule; do
        [[ -z "$rule" ]] && continue
        
        # Extract destination from DNAT rule
        local dest
        dest=$(echo "$rule" | grep -oP '(?<=--to-destination )\S+') || true
        if [[ -z "$dest" ]]; then
            continue
        fi
        
        local dest_ip="${dest%:*}"
        local dest_port="${dest#*:}"
        
        # Check for exact port match in FORWARD rules
        local has_exact_match=false
        local has_broad_match=false
        
        if echo "$filter_rules" | grep -q -- "-d $dest_ip.*--dport $dest_port"; then
            has_exact_match=true
        elif echo "$filter_rules" | grep -q -- "-d $dest_ip"; then
            has_broad_match=true
        fi
        
        if [[ "$has_exact_match" == "true" ]]; then
            echo -e "  - DNAT to $dest: ${GREEN}OK${NC} (exact FORWARD match)"
        elif [[ "$has_broad_match" == "true" ]]; then
            echo -e "  - DNAT to $dest: ${ORANGE}WARN${NC} (broad match - all ports to $dest_ip allowed)"
            ((warnings++))
        else
            echo -e "  - DNAT to $dest: ${RED}MISSING${NC} FORWARD rule!"
            echo "    Add to $CUSTOM_DIR/filter.rules:"
            echo "    -A FORWARD -i <wan> -o <lan_br> -p tcp -d $dest_ip --dport $dest_port -m conntrack --ctstate NEW -j ACCEPT"
            ((warnings++))
        fi
    done < <(echo "$nat_rules" | grep -F "DNAT" || true)
    
    if [[ $warnings -eq 0 ]]; then
        echo "  - All DNAT rules validated successfully"
    else
        echo "  - $warnings warning(s) found"
    fi
    
    # Always return 0 - validation is informational, not fatal
    return 0
}

# =============================================================================
# Configuration Persistence
# =============================================================================

save_config() {
    local disable_ipv6="$1"
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# VPN Hardening Configuration
# Generated: $(date)
DISABLE_IPV6=${disable_ipv6}
EOF
    log_info "Configuration saved to $CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "${DISABLE_IPV6:-true}"
    else
        echo "true"  # Default to blocking IPv6
    fi
}

# =============================================================================
# Rule Generation
# =============================================================================

generate_ipv4_rules() {
    local wg_nic="$1"
    local wg_port="$2"
    local wg_net="$3"
    local wg_net_is_32="$4"
    local wan_if="$5"
    local lan_bridges="$6"
    
    cat << EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# --- Loopback ---
-A INPUT -i lo -j ACCEPT

# --- Connection tracking ---
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP

# --- WireGuard UDP port (entry point from internet) ---
-A INPUT -p udp --dport ${wg_port} -j ACCEPT

# --- Allow all traffic from WireGuard INTERFACE ---
-A INPUT -i ${wg_nic} -j ACCEPT

# --- FORWARD: WireGuard clients to internet ---
-A FORWARD -i ${wg_nic} -j ACCEPT
-A FORWARD -o ${wg_nic} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

EOF

    # LAN bridge forwarding rules
    if [[ -n "$lan_bridges" ]]; then
        echo "# --- VM Bridge Forwarding (LAN bridges only) ---"
        for br in $lan_bridges; do
            local br_net=$(get_bridge_network "$br")
            if [[ -n "$br_net" ]]; then
                echo "-A FORWARD -i ${br} -o ${wan_if} -s ${br_net} -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
                echo "-A FORWARD -i ${wan_if} -o ${br} -d ${br_net} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
                echo "-A FORWARD -i ${br} -o ${br} -j ACCEPT"
            fi
        done
        echo ""
    fi

    # Custom filter rules
    local custom_filter=$(get_custom_rules "filter")
    if [[ -n "$custom_filter" ]]; then
        echo "# --- Custom filter rules from $CUSTOM_DIR/filter.rules ---"
        echo "$custom_filter"
        echo ""
    fi
    
    echo "COMMIT"
    echo ""
    
    # Mangle table
    cat << EOF
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# --- MSS clamping to avoid MTU issues ---
-A FORWARD -o ${wan_if} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
-A FORWARD -o ${wg_nic} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

EOF

    local custom_mangle=$(get_custom_rules "mangle")
    if [[ -n "$custom_mangle" ]]; then
        echo "# --- Custom mangle rules ---"
        echo "$custom_mangle"
        echo ""
    fi

    echo "COMMIT"
    echo ""
    
    # NAT table
    cat << EOF
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

EOF

    # WireGuard NAT - use subnet-based if available, interface-based as fallback
    if [[ -n "$wg_net" && "$wg_net_is_32" != "true" ]]; then
        echo "# --- NAT for WireGuard clients (subnet-based) ---"
        echo "-A POSTROUTING -s ${wg_net} -o ${wan_if} -j MASQUERADE"
    else
        echo "# --- NAT for WireGuard clients (interface-based fallback) ---"
        if [[ "$wg_net_is_32" == "true" ]]; then
            echo "# WireGuard uses /32 addresses; NAT all traffic from WG interface"
        else
            echo "# Subnet detection failed; NAT all traffic from WG interface"
        fi
        echo "-A POSTROUTING -o ${wan_if} -m mark --mark 0x1 -j MASQUERADE"
        # Also add interface-based rule as primary
        echo "-A POSTROUTING ! -o ${wg_nic} -m addrtype ! --src-type LOCAL -m conntrack --ctstate NEW -j MASQUERADE"
    fi
    echo ""

    # LAN bridge NAT
    if [[ -n "$lan_bridges" ]]; then
        echo "# --- NAT for VM Subnets ---"
        for br in $lan_bridges; do
            local br_net=$(get_bridge_network "$br")
            if [[ -n "$br_net" ]]; then
                echo "-A POSTROUTING -s ${br_net} -o ${wan_if} -j MASQUERADE"
            fi
        done
        echo ""
    fi
    
    # Custom NAT rules
    local custom_nat=$(get_custom_rules "nat")
    if [[ -n "$custom_nat" ]]; then
        echo "# --- Custom NAT rules from $CUSTOM_DIR/nat.rules ---"
        echo "$custom_nat"
        echo ""
    fi
    
    echo "COMMIT"
}

generate_ipv6_rules() {
    local wg_nic="$1"
    local wg_port="$2"
    local disable_ipv6="$3"
    
    if [[ "$disable_ipv6" == "true" ]]; then
        cat << EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# IPv6 completely disabled
-A INPUT -j DROP
-A FORWARD -j DROP
-A OUTPUT -j DROP

COMMIT
EOF
    else
        cat << EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# --- Loopback ---
-A INPUT -i lo -j ACCEPT

# --- Connection tracking ---
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP

# --- ICMPv6 (required for IPv6 to function) ---
-A INPUT -p ipv6-icmp -j ACCEPT

# --- WireGuard UDP port ---
-A INPUT -p udp --dport ${wg_port} -j ACCEPT

# --- Allow all traffic from WireGuard interface ---
-A INPUT -i ${wg_nic} -j ACCEPT

# --- FORWARD for WireGuard only ---
-A FORWARD -i ${wg_nic} -j ACCEPT
-A FORWARD -o ${wg_nic} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

COMMIT
EOF
    fi
}

# =============================================================================
# System Configuration
# =============================================================================

ensure_ip_forwarding() {
    log_step "Enabling IP forwarding..."
    
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true
    
    local sysctl_file="/etc/sysctl.d/99-vpn-forwarding.conf"
    cat > "$sysctl_file" << EOF
# IP forwarding for VPN and VM NAT
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    
    log_info "IP forwarding enabled and persisted to $sysctl_file"
}

# =============================================================================
# Application Functions
# =============================================================================

apply_rules() {
    local v4_rules="$1"
    local v6_rules="$2"
    
    log_step "Applying IPv4 rules atomically..."
    echo "$v4_rules" | iptables-restore -w
    
    log_step "Applying IPv6 rules atomically..."
    echo "$v6_rules" | ip6tables-restore -w
    
    log_info "Rules applied successfully."
}

save_rules() {
    local v4_rules="$1"
    local v6_rules="$2"
    
    if [[ "$KEEP_PVE_FIREWALL" == "true" ]]; then
        log_warn "Proxmox firewall is active - NOT saving rules"
        log_warn "Rules will be lost on reboot."
        return 0
    fi
    
    mkdir -p "$RULES_DIR"
    
    log_step "Saving rules for persistence..."
    echo "$v4_rules" > "$RULES_DIR/rules.v4"
    echo "$v6_rules" > "$RULES_DIR/rules.v6"
    
    if ! dpkg -l 2>/dev/null | grep -q iptables-persistent; then
        log_step "Installing iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1
    fi
    
    # Also update netfilter-persistent's saved rules
    netfilter-persistent save > /dev/null 2>&1 || true
    
    log_info "Rules saved to $RULES_DIR/"
}

# =============================================================================
# Regenerate Rules from Current State
# =============================================================================

regenerate_rules() {
    local quiet="${1:-false}"
    
    # Check WireGuard
    if [[ ! -e /etc/wireguard/params ]]; then
        log_error "WireGuard not configured. Cannot regenerate rules."
        return 1
    fi
    
    source /etc/wireguard/params
    
    # Detect configuration
    local detected_wan=$(detect_wan_interface)
    local wg_result wg_net wg_net_is_32
    wg_result=$(detect_wg_network "$SERVER_WG_NIC")
    IFS='|' read -r wg_net wg_net_is_32 <<< "$wg_result"
    
    # Use detected WAN or fall back to configured
    local wan_if="${detected_wan:-$SERVER_PUB_NIC}"
    
    # Get bridges
    local bridge_info=$(categorize_bridges 2>/dev/null)
    local lan_bridges=$(echo "$bridge_info" | grep "^LAN:" | cut -d: -f2 | xargs)
    
    # Load IPv6 preference
    local disable_ipv6=$(load_config)
    
    # Ensure custom dirs exist
    setup_custom_dirs
    
    # Generate rules
    local v4_rules=$(generate_ipv4_rules \
        "$SERVER_WG_NIC" \
        "$SERVER_PORT" \
        "$wg_net" \
        "$wg_net_is_32" \
        "$wan_if" \
        "$lan_bridges")
    
    local v6_rules=$(generate_ipv6_rules \
        "$SERVER_WG_NIC" \
        "$SERVER_PORT" \
        "$disable_ipv6")
    
    if [[ "$quiet" != "true" ]]; then
        log_info "Regenerated rules from current configuration"
        log_info "  WireGuard: $SERVER_WG_NIC (port $SERVER_PORT)"
        if [[ "$wg_net_is_32" == "true" ]]; then
            log_info "  WG Network: /32 (interface-based NAT)"
        else
            log_info "  WG Network: ${wg_net:-unknown}"
        fi
        log_info "  WAN: $wan_if"
        log_info "  LAN bridges: ${lan_bridges:-none}"
    fi
    
    # Return rules via global variables (bash limitation)
    REGEN_V4_RULES="$v4_rules"
    REGEN_V6_RULES="$v6_rules"
}

# =============================================================================
# Status Functions
# =============================================================================

show_status() {
    echo ""
    echo "=== Firewall Status ==="
    echo ""
    
    echo "Proxmox Firewall:"
    local pve_fw=$(detect_proxmox_firewall)
    case "$pve_fw" in
        nftables) echo "  - proxmox-firewall (nftables): ACTIVE - may conflict!" ;;
        iptables-pve) echo "  - pve-firewall (iptables): ACTIVE - may conflict!" ;;
        none) echo "  - No Proxmox firewall active" ;;
    esac
    echo ""
    
    echo "Network Interfaces:"
    local wan_if=$(detect_wan_interface)
    echo "  - WAN (default route): ${wan_if:-unknown}"
    
    if [[ -e /etc/wireguard/params ]]; then
        source /etc/wireguard/params
        local wg_result wg_net wg_net_is_32
        wg_result=$(detect_wg_network "${SERVER_WG_NIC:-wg0}")
        IFS='|' read -r wg_net wg_net_is_32 <<< "$wg_result"
        
        echo "  - WireGuard: ${SERVER_WG_NIC:-unknown}"
        if [[ "$wg_net_is_32" == "true" ]]; then
            echo "  - WireGuard network: /32 (interface-based NAT)"
        else
            echo "  - WireGuard network: ${wg_net:-unknown}"
        fi
        echo "  - WireGuard port: ${SERVER_PORT:-unknown}/udp"
        if ip link show "${SERVER_WG_NIC:-wg0}" &>/dev/null; then
            echo "  - WireGuard status: UP"
        else
            echo "  - WireGuard status: DOWN"
        fi
    fi
    echo ""
    
    echo "Bridges:"
    local bridge_info=$(categorize_bridges 2>/dev/null)
    echo "$bridge_info" | while read line; do
        local type=$(echo "$line" | cut -d: -f1)
        local bridges=$(echo "$line" | cut -d: -f2)
        if [[ -n "$bridges" ]]; then
            for br in $bridges; do
                local net=$(get_bridge_network "$br")
                echo "  - $br ($type): ${net:-no subnet}"
            done
        fi
    done
    
    # Check for bridges without IPs
    for br in $(detect_bridges); do
        local net=$(get_bridge_network "$br")
        if [[ -z "$net" && "$br" != "$(detect_wan_interface)" ]]; then
            echo -e "  - $br: ${ORANGE}no IP (not NATed)${NC}"
        fi
    done
    echo ""
    
    echo "IP Forwarding:"
    local fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    echo "  - IPv4: $([ "$fwd" == "1" ] && echo "ENABLED" || echo "DISABLED")"
    local fwd6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)
    echo "  - IPv6: $([ "$fwd6" == "1" ] && echo "ENABLED" || echo "DISABLED")"
    echo ""
    
    echo "Custom Rules:"
    if [[ -d "$CUSTOM_DIR" ]]; then
        for f in "$CUSTOM_DIR"/*.rules; do
            if [[ -f "$f" ]]; then
                local count=$(grep -c -v '^\s*#\|^\s*$' "$f" 2>/dev/null || echo 0)
                echo "  - $(basename "$f"): $count rules"
            fi
        done
        echo ""
        echo "DNAT Validation:"
        validate_custom_rules
    else
        echo "  - No custom rules directory"
    fi
    echo ""
    
    echo "Pending Rollback:"
    if is_rollback_pending; then
        echo -e "  - ${ORANGE}YES${NC} - Run '$0 --cancel' to make permanent"
    else
        echo "  - No"
    fi
    echo ""
}

# =============================================================================
# Interactive Setup
# =============================================================================

interactive_setup() {
    echo ""
    echo "=========================================="
    echo "  Proxmox VPN-Only Access Hardening v5"
    echo "=========================================="
    echo ""
    
    # Check for Proxmox firewall conflict
    local pve_fw=$(detect_proxmox_firewall)
    if [[ "$pve_fw" != "none" ]]; then
        log_warn "Proxmox firewall detected: $pve_fw"
        echo ""
        echo "Options:"
        echo "  1) Disable Proxmox firewall and use this script (recommended)"
        echo "  2) Keep Proxmox firewall (rules won't persist)"
        echo "  3) Exit and configure via Proxmox UI instead"
        echo ""
        read -rp "Choose [1-3]: " fw_choice
        
        case "$fw_choice" in
            1)
                log_step "Disabling Proxmox firewall..."
                systemctl stop pve-firewall 2>/dev/null || true
                systemctl disable pve-firewall 2>/dev/null || true
                systemctl mask pve-firewall 2>/dev/null || true
                systemctl stop proxmox-firewall 2>/dev/null || true
                systemctl disable proxmox-firewall 2>/dev/null || true
                systemctl mask proxmox-firewall 2>/dev/null || true
                log_info "Proxmox firewall masked (won't re-enable on reboot)"
                KEEP_PVE_FIREWALL=false
                ;;
            2)
                log_warn "Keeping Proxmox firewall - rules will NOT persist!"
                KEEP_PVE_FIREWALL=true
                ;;
            3)
                echo "Exiting."
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
    echo ""
    
    # Load WireGuard config
    check_wireguard
    source /etc/wireguard/params
    
    # Detect configuration using structured return
    local detected_wan=$(detect_wan_interface)
    local wg_result wg_net wg_net_is_32
    wg_result=$(detect_wg_network "$SERVER_WG_NIC")
    IFS='|' read -r wg_net wg_net_is_32 <<< "$wg_result"
    
    echo "Detected configuration:"
    echo "  WireGuard interface: ${SERVER_WG_NIC}"
    if [[ "$wg_net_is_32" == "true" ]]; then
        echo "  WireGuard network: /32 - will use interface-based NAT"
    else
        echo "  WireGuard network: ${wg_net:-unknown}"
    fi
    echo "  WireGuard port: ${SERVER_PORT}"
    echo "  WAN interface: ${detected_wan}"
    echo ""
    
    # Warn if mismatch
    if [[ "$detected_wan" != "$SERVER_PUB_NIC" ]]; then
        log_warn "SERVER_PUB_NIC ($SERVER_PUB_NIC) differs from detected ($detected_wan)"
        read -rp "Use detected WAN interface ($detected_wan)? [Y/n]: " use_detected
        use_detected=${use_detected:-Y}
        if [[ $use_detected =~ ^[Yy]$ ]]; then
            SERVER_PUB_NIC="$detected_wan"
        fi
    fi
    echo ""
    
    # Categorize bridges
    echo "Bridge detection:"
    local bridge_info=$(categorize_bridges)
    local wan_bridge=$(echo "$bridge_info" | grep "^WAN:" | cut -d: -f2 | xargs)
    local lan_bridges=$(echo "$bridge_info" | grep "^LAN:" | cut -d: -f2 | xargs)
    
    echo "  WAN bridge: ${wan_bridge:-none}"
    echo "  LAN bridges: ${lan_bridges:-none}"
    echo ""
    
    # IPv6 handling
    echo "IPv6 Configuration:"
    echo "  1) Block all IPv6 (RECOMMENDED)"
    echo "  2) Allow IPv6 for WireGuard only"
    read -rp "Choose [1-2, default: 1]: " ipv6_choice
    ipv6_choice=${ipv6_choice:-1}
    
    local disable_ipv6="true"
    [[ "$ipv6_choice" == "2" ]] && disable_ipv6="false"
    echo ""
    
    # Setup custom rules directory
    setup_custom_dirs
    
    # Validate existing custom rules
    echo "Validating custom rules..."
    validate_custom_rules
    echo ""
    
    # Generate rules
    log_step "Generating firewall rules..."
    
    local v4_rules=$(generate_ipv4_rules \
        "$SERVER_WG_NIC" \
        "$SERVER_PORT" \
        "$wg_net" \
        "$wg_net_is_32" \
        "$SERVER_PUB_NIC" \
        "$lan_bridges")
    
    local v6_rules=$(generate_ipv6_rules \
        "$SERVER_WG_NIC" \
        "$SERVER_PORT" \
        "$disable_ipv6")
    
    # Show rules
    echo ""
    echo "=== Generated IPv4 Rules ==="
    echo "$v4_rules"
    echo ""
    echo "=== Generated IPv6 Rules ==="
    echo "$v6_rules"
    echo ""
    
    # Final confirmation
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: This will restrict access to WireGuard VPN only!     ║${NC}"
    echo -e "${RED}║  Make sure you have a working WireGuard connection NOW.        ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  A ${ROLLBACK_TIMEOUT}-second automatic rollback is scheduled.              ║${NC}"
    echo -e "${RED}║  (Rollback survives SSH disconnects via systemd)               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Are you connected via WireGuard RIGHT NOW? [y/N]: " connected
    
    if [[ ! $connected =~ ^[Yy]$ ]]; then
        log_error "Please connect via WireGuard first!"
        exit 1
    fi
    
    read -rp "Apply rules with ${ROLLBACK_TIMEOUT}s rollback? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Execute
    backup_current_rules
    ensure_ip_forwarding
    schedule_rollback "$ROLLBACK_TIMEOUT"
    apply_rules "$v4_rules" "$v6_rules"
    
    echo ""
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Rules applied! You have ${ROLLBACK_TIMEOUT} seconds to verify.${NC}"
    echo -e "${GREEN}  TEST in a NEW terminal, then run: $0 --cancel${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -rp "Verified access? Cancel rollback and save? [y/N]: " verified
    if [[ $verified =~ ^[Yy]$ ]]; then
        cancel_rollback
        save_config "$disable_ipv6"
        save_rules "$v4_rules" "$v6_rules"
        
        echo ""
        log_info "Hardening complete!"
        echo ""
        echo "Summary:"
        echo "  - WireGuard port ${SERVER_PORT}/udp: OPEN"
        echo "  - All other ports: VPN only"
        if [[ "$wg_net_is_32" == "true" ]]; then
            echo "  - WireGuard NAT: interface-based"
        else
            echo "  - WireGuard network: ${wg_net}"
        fi
        echo "  - IPv6: $([ "$disable_ipv6" == "true" ] && echo "BLOCKED" || echo "WG only")"
        echo ""
        echo "Custom rules: $CUSTOM_DIR/"
        echo ""
        echo "Note: Rules will regenerate from custom.d on boot via --apply"
    else
        log_warn "Rules NOT saved. Rollback in ~${ROLLBACK_TIMEOUT}s."
    fi
}

# =============================================================================
# Main Entry Point
# =============================================================================

check_root

case "${1:-}" in
    --apply)
        # Regenerate rules from current config (including custom.d) and apply
        log_step "Regenerating and applying rules..."
        regenerate_rules "false"
        apply_rules "$REGEN_V4_RULES" "$REGEN_V6_RULES"
        log_info "Rules applied (regenerated from current configuration)"
        ;;
    --save)
        # Regenerate and save rules
        log_step "Regenerating and saving rules..."
        regenerate_rules "false"
        save_rules "$REGEN_V4_RULES" "$REGEN_V6_RULES"
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
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "Options:"
        echo "  (none)      Interactive setup"
        echo "  --apply     Regenerate from config and apply rules (for boot)"
        echo "  --save      Regenerate and save rules for persistence"
        echo "  --cancel    Cancel pending rollback"
        echo "  --status    Show firewall status"
        echo "  --restore   Restore last backup"
        echo "  --help      Show this help"
        echo ""
        echo "After adding port forwards via proxmox-network-manager.sh,"
        echo "run '$0 --save' to persist them across reboots."
        ;;
    "")
        interactive_setup
        ;;
    *)
        log_error "Unknown option: $1"
        exit 1
        ;;
esac
