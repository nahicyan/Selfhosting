#!/bin/bash
# =============================================================================
# Proxmox Private Network & Port Forwarding Manager v3.1
# =============================================================================
# Manages private VM networks (NAT) and port forwarding rules on Proxmox hosts.
#
# This script integrates with proxmox-vpn-hardening.sh by writing rules to:
#   /etc/iptables/custom.d/nat.rules
#   /etc/iptables/custom.d/filter.rules
#
# Features:
#   - View current private networks and port forwards
#   - Create private networks with NAT
#   - Add/remove port forwarding rules
#   - Proper CIDR calculation (uses Python ipaddress)
#   - Idempotent rule application (no duplicates)
#   - Safe config management via interfaces.d/
#   - Auto-persistence: saves rules after changes
#   - Integrates with VPN hardening script
#
# Usage:
#   ./proxmox-network-manager.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INTERFACES_FILE="/etc/network/interfaces"
INTERFACES_DIR="/etc/network/interfaces.d"
CUSTOM_DIR="/etc/iptables/custom.d"
BACKUP_DIR="/root/network-backups"
HARDENING_SCRIPT="/root/proxmox-vpn-hardening.sh"

# =============================================================================
# Helper Functions
# =============================================================================

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${ORANGE}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${BLUE}[→]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_python() {
    if ! command -v python3 &>/dev/null; then
        log_error "Python3 is required for CIDR calculations"
        exit 1
    fi
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    cp "$INTERFACES_FILE" "$BACKUP_DIR/interfaces.$timestamp" 2>/dev/null || true
    
    if [[ -d "$CUSTOM_DIR" ]]; then
        tar -czf "$BACKUP_DIR/custom.d.$timestamp.tar.gz" -C "$(dirname "$CUSTOM_DIR")" "$(basename "$CUSTOM_DIR")" 2>/dev/null || true
    fi
    
    log_info "Backup saved to $BACKUP_DIR/*.$timestamp"
}

# =============================================================================
# Persistence Integration
# =============================================================================

# Persist rules after changes - integrates with hardening script or netfilter-persistent
persist_rules() {
    local auto="${1:-true}"
    
    # Check if Proxmox firewall is active (don't persist in that case)
    if systemctl is-active --quiet pve-firewall 2>/dev/null || \
       systemctl is-active --quiet proxmox-firewall 2>/dev/null; then
        if [[ "$auto" == "true" ]]; then
            log_warn "Proxmox firewall active - rules applied live but won't persist"
        fi
        return 0
    fi
    
    # Preferred: use hardening script's --save to regenerate full ruleset
    if [[ -x "$HARDENING_SCRIPT" ]]; then
        log_step "Saving rules via hardening script..."
        "$HARDENING_SCRIPT" --save 2>/dev/null && {
            log_info "Rules persisted (regenerated via $HARDENING_SCRIPT)"
            return 0
        }
    fi
    
    # Fallback: use netfilter-persistent directly
    if command -v netfilter-persistent &>/dev/null; then
        log_step "Saving rules via netfilter-persistent..."
        netfilter-persistent save > /dev/null 2>&1 && {
            log_info "Rules persisted via netfilter-persistent"
            return 0
        }
    fi
    
    log_warn "Could not persist rules automatically"
    log_warn "Run '$HARDENING_SCRIPT --save' manually to persist"
    return 1
}

# =============================================================================
# CIDR Calculation (Python-based - accurate for all subnet sizes)
# =============================================================================

# Calculate network address from IP/CIDR
calc_network() {
    local ip_cidr="$1"
    python3 -c "
import ipaddress
try:
    iface = ipaddress.ip_interface('$ip_cidr')
    print(iface.network)
except Exception as e:
    print('')
" 2>/dev/null
}

# Check if IP is in a network
ip_in_network() {
    local ip="$1"
    local network="$2"
    python3 -c "
import ipaddress, sys
try:
    net = ipaddress.ip_network('$network', strict=False)
    ip = ipaddress.ip_address('$ip')
    sys.exit(0 if ip in net else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Validate IP/CIDR format
validate_ip_cidr() {
    local ip_cidr="$1"
    python3 -c "
import ipaddress, sys
try:
    ipaddress.ip_interface('$ip_cidr')
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Validate IP address
validate_ip() {
    local ip="$1"
    python3 -c "
import ipaddress, sys
try:
    ipaddress.ip_address('$ip')
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# =============================================================================
# Detection Functions
# =============================================================================

get_wan_bridge() {
    ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

get_all_bridges() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1
}

get_bridge_info() {
    local br="$1"
    ip -o -4 addr show dev "$br" 2>/dev/null | awk '{print $4}' | head -1
}

get_bridge_network() {
    local br="$1"
    local addr=$(get_bridge_info "$br")
    if [[ -n "$addr" ]]; then
        calc_network "$addr"
    fi
}

# FIX: Corrected grep pattern - in iptables output, -s comes BEFORE -j MASQUERADE
# Example output: -A POSTROUTING -s 192.168.1.0/24 -o vmbr0 -j MASQUERADE
has_nat_configured() {
    local br="$1"
    local br_net=$(get_bridge_network "$br")
    
    if [[ -n "$br_net" ]]; then
        # Check for source network followed by MASQUERADE (correct order)
        iptables -w -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s ${br_net}.*MASQUERADE" && return 0
    fi
    return 1
}

get_private_bridges() {
    local wan=$(get_wan_bridge)
    local bridges=$(get_all_bridges)
    local private_bridges=""
    
    for br in $bridges; do
        if [[ "$br" != "$wan" ]]; then
            local info=$(get_bridge_info "$br")
            if [[ -n "$info" ]]; then
                if [[ "$info" =~ ^10\. ]] || [[ "$info" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || [[ "$info" =~ ^192\.168\. ]]; then
                    private_bridges="$private_bridges $br"
                fi
            fi
        fi
    done
    
    echo "$private_bridges" | xargs
}

# FIX: Improved port forward detection with proper deduplication
# The check now correctly matches iptables output format where --dport comes before DNAT
get_port_forwards() {
    local live_rules=""
    
    # From live iptables - collect all active DNAT rules
    while read -r rule; do
        local iface=$(echo "$rule" | grep -oP '(?<=-i )\S+')
        local proto=$(echo "$rule" | grep -oP '(?<=-p )\S+')
        local dport=$(echo "$rule" | grep -oP '(?<=--dport )\S+')
        local dest=$(echo "$rule" | grep -oP '(?<=--to-destination )\S+')
        
        if [[ -n "$dport" && -n "$dest" ]]; then
            echo "live:$proto:$dport->$dest"
            live_rules="${live_rules}${proto}:${dport}:${dest}"$'\n'
        fi
    done < <(iptables -w -t nat -S PREROUTING 2>/dev/null | grep "DNAT")
    
    # From custom.d (may not be applied yet)
    if [[ -f "$CUSTOM_DIR/nat.rules" ]]; then
        while read -r rule; do
            local proto=$(echo "$rule" | grep -oP '(?<=-p )\S+')
            local dport=$(echo "$rule" | grep -oP '(?<=--dport )\S+')
            local dest=$(echo "$rule" | grep -oP '(?<=--to-destination )\S+')
            
            if [[ -n "$dport" && -n "$dest" ]]; then
                local key="${proto}:${dport}:${dest}"
                # Check if this exact combination is already in live rules
                if ! echo "$live_rules" | grep -qF "$key"; then
                    echo "pending:$proto:$dport->$dest"
                fi
            fi
        done < <(grep -v '^\s*#' "$CUSTOM_DIR/nat.rules" 2>/dev/null | grep "DNAT")
    fi
}

# =============================================================================
# Custom Rules Management (Integration with Hardening Script)
# =============================================================================

setup_custom_dirs() {
    mkdir -p "$CUSTOM_DIR"
    
    if [[ ! -f "$CUSTOM_DIR/filter.rules" ]]; then
        cat > "$CUSTOM_DIR/filter.rules" << 'EOF'
# Custom filter rules - managed by proxmox-network-manager.sh
# These rules are included by proxmox-vpn-hardening.sh
#
# Format: standard iptables -A syntax
EOF
    fi
    
    if [[ ! -f "$CUSTOM_DIR/nat.rules" ]]; then
        cat > "$CUSTOM_DIR/nat.rules" << 'EOF'
# Custom NAT rules - managed by proxmox-network-manager.sh
# These rules are included by proxmox-vpn-hardening.sh
#
# Format: standard iptables -t nat -A syntax
EOF
    fi
}

# Add rule to custom file if not already present
add_custom_rule() {
    local file="$1"
    local rule="$2"
    local comment="$3"
    
    # Check if rule already exists
    if grep -qF "$rule" "$file" 2>/dev/null; then
        return 0  # Already exists
    fi
    
    # Add with comment
    echo "" >> "$file"
    if [[ -n "$comment" ]]; then
        echo "# $comment" >> "$file"
    fi
    echo "$rule" >> "$file"
}

# Remove rule from custom file
remove_custom_rule() {
    local file="$1"
    local pattern="$2"
    
    if [[ -f "$file" ]]; then
        # Remove the rule and its comment (line before if it starts with #)
        sed -i "/$pattern/d" "$file"
        # Clean up empty lines
        sed -i '/^$/N;/^\n$/d' "$file"
    fi
}

# Apply rules immediately using -C || -A (idempotent)
apply_rule_idempotent() {
    local table="$1"
    shift
    local rule="$@"
    
    if [[ "$table" == "filter" ]]; then
        iptables -w -C $rule 2>/dev/null || iptables -w -A $rule
    else
        iptables -w -t "$table" -C $rule 2>/dev/null || iptables -w -t "$table" -A $rule
    fi
}

# Remove rule from iptables
remove_rule() {
    local table="$1"
    shift
    local rule="$@"
    
    if [[ "$table" == "filter" ]]; then
        iptables -w -D $rule 2>/dev/null || true
    else
        iptables -w -t "$table" -D $rule 2>/dev/null || true
    fi
}

# =============================================================================
# Display Functions
# =============================================================================

show_status() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           Proxmox Network Status                               ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # WAN Bridge
    local wan=$(get_wan_bridge)
    local wan_ip=$(get_bridge_info "$wan")
    echo -e "${CYAN}WAN Bridge:${NC}"
    echo -e "  ${GREEN}$wan${NC} - $wan_ip (default route)"
    echo ""
    
    # Private Bridges
    echo -e "${CYAN}Private Bridges:${NC}"
    local private_bridges=$(get_private_bridges)
    
    if [[ -z "$private_bridges" ]]; then
        echo -e "  ${ORANGE}None configured${NC}"
    else
        for br in $private_bridges; do
            local br_ip=$(get_bridge_info "$br")
            local br_net=$(get_bridge_network "$br")
            local nat_status="${RED}No NAT${NC}"
            
            if has_nat_configured "$br"; then
                nat_status="${GREEN}NAT Active${NC}"
            fi
            
            echo -e "  ${GREEN}$br${NC}"
            echo -e "    IP: $br_ip"
            echo -e "    Network: ${br_net:-unknown}"
            echo -e "    Internet: $nat_status"
        done
    fi
    echo ""
    
    # IP Forwarding
    local fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    echo -e "${CYAN}IP Forwarding:${NC}"
    if [[ "$fwd" == "1" ]]; then
        echo -e "  ${GREEN}Enabled${NC}"
    else
        echo -e "  ${RED}Disabled${NC} (VMs won't reach internet)"
    fi
    echo ""
    
    # Port Forwards
    echo -e "${CYAN}Port Forwards:${NC}"
    local forwards=$(get_port_forwards)
    
    if [[ -z "$forwards" ]]; then
        echo -e "  ${ORANGE}None configured${NC}"
    else
        echo -e "  ${BOLD}Status   Proto:Port → Destination${NC}"
        echo "$forwards" | sort -u | while read -r fwd; do
            local status=$(echo "$fwd" | cut -d: -f1)
            local proto=$(echo "$fwd" | cut -d: -f2)
            local rest=$(echo "$fwd" | cut -d: -f3-)
            local src_port=$(echo "$rest" | cut -d'-' -f1)
            local dest=$(echo "$rest" | cut -d'>' -f2)
            
            if [[ "$status" == "live" ]]; then
                echo -e "  ${GREEN}[active]${NC}  $proto:${BOLD}$src_port${NC} → $dest"
            else
                echo -e "  ${ORANGE}[pending]${NC} $proto:${BOLD}$src_port${NC} → $dest"
            fi
        done
    fi
    echo ""
    
    # Integration status
    echo -e "${CYAN}Integration:${NC}"
    if [[ -x "$HARDENING_SCRIPT" ]]; then
        echo -e "  Hardening script: ${GREEN}Found${NC} (executable)"
    elif [[ -f "$HARDENING_SCRIPT" ]]; then
        echo -e "  Hardening script: ${ORANGE}Found (not executable)${NC}"
    else
        echo -e "  Hardening script: ${ORANGE}Not found${NC} ($HARDENING_SCRIPT)"
    fi
    if [[ -d "$CUSTOM_DIR" ]]; then
        local nat_count=$(grep -c -v '^\s*#\|^\s*$' "$CUSTOM_DIR/nat.rules" 2>/dev/null || echo 0)
        local filter_count=$(grep -c -v '^\s*#\|^\s*$' "$CUSTOM_DIR/filter.rules" 2>/dev/null || echo 0)
        echo -e "  Custom NAT rules: $nat_count"
        echo -e "  Custom filter rules: $filter_count"
    fi
    
    # Persistence status
    if systemctl is-active --quiet pve-firewall 2>/dev/null || \
       systemctl is-active --quiet proxmox-firewall 2>/dev/null; then
        echo -e "  Persistence: ${ORANGE}Disabled (Proxmox FW active)${NC}"
    elif [[ -x "$HARDENING_SCRIPT" ]]; then
        echo -e "  Persistence: ${GREEN}Auto (via hardening script)${NC}"
    elif command -v netfilter-persistent &>/dev/null; then
        echo -e "  Persistence: ${GREEN}Auto (via netfilter-persistent)${NC}"
    else
        echo -e "  Persistence: ${RED}Manual${NC}"
    fi
    echo ""
}

# =============================================================================
# Private Network Setup
# =============================================================================

setup_private_network() {
    echo ""
    echo -e "${BOLD}=== Setup Private Network ===${NC}"
    echo ""
    
    local wan=$(get_wan_bridge)
    echo "WAN bridge detected: $wan"
    echo ""
    
    # Get bridge name
    local default_br="vmbr1"
    read -rp "Private bridge name [$default_br]: " bridge_name
    bridge_name=${bridge_name:-$default_br}
    
    # Validate bridge name
    if [[ ! "$bridge_name" =~ ^vmbr[0-9]+$ ]]; then
        log_error "Invalid bridge name. Must be vmbrX format."
        return 1
    fi
    
    if [[ "$bridge_name" == "$wan" ]]; then
        log_error "Cannot use WAN bridge ($wan) as private network."
        return 1
    fi
    
    # Check if bridge already exists
    local br_exists=false
    if ip link show "$bridge_name" &>/dev/null; then
        br_exists=true
        local current_ip=$(get_bridge_info "$bridge_name")
        log_warn "Bridge $bridge_name already exists with IP: ${current_ip:-none}"
        read -rp "Reconfigure it? [y/N]: " reconf
        if [[ ! "$reconf" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # Get IP configuration
    echo ""
    echo "Enter the private network configuration."
    echo "Example: 192.168.1.1/24 means gateway 192.168.1.1, VMs get 192.168.1.x"
    echo ""
    
    local default_ip="192.168.1.1/24"
    read -rp "Bridge IP/CIDR [$default_ip]: " bridge_ip
    bridge_ip=${bridge_ip:-$default_ip}
    
    # Validate IP format using Python
    if ! validate_ip_cidr "$bridge_ip"; then
        log_error "Invalid IP/CIDR format."
        return 1
    fi
    
    # Calculate network using Python (accurate for all CIDR sizes)
    local network=$(calc_network "$bridge_ip")
    if [[ -z "$network" ]]; then
        log_error "Failed to calculate network from $bridge_ip"
        return 1
    fi
    
    local ip_only="${bridge_ip%/*}"
    
    echo ""
    echo "Configuration summary:"
    echo "  Bridge: $bridge_name"
    echo "  IP: $bridge_ip"
    echo "  Network: $network"
    echo "  WAN interface: $wan"
    echo ""
    
    read -rp "Apply this configuration? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
    fi
    
    # Backup
    backup_configs
    
    # Enable IP forwarding
    log_step "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
    
    # Check if bridge already defined in interfaces file
    if grep -q "^iface $bridge_name " "$INTERFACES_FILE" 2>/dev/null; then
        log_warn "Bridge $bridge_name already in $INTERFACES_FILE - updating..."
        # Remove existing bridge config block (from auto/iface line to next blank line or auto/iface)
        sed -i "/^auto $bridge_name/,/^$/d" "$INTERFACES_FILE" 2>/dev/null || true
        sed -i "/^iface $bridge_name /,/^$/d" "$INTERFACES_FILE" 2>/dev/null || true
    fi
    
    # Write bridge config directly to main interfaces file (Proxmox GUI reads this)
    log_step "Adding bridge config to $INTERFACES_FILE..."
    cat >> "$INTERFACES_FILE" << EOF

# Private bridge $bridge_name - managed by proxmox-network-manager.sh
auto $bridge_name
iface $bridge_name inet static
        address $bridge_ip
        bridge-ports none
        bridge-stp off
        bridge-fd 0
EOF
    
    # Apply NAT/FORWARD rules immediately for current session
    # NOTE: We don't write these to custom.d - the hardening script will auto-detect
    # this bridge and add the rules when it regenerates (--apply or --save)
    log_step "Applying NAT/FORWARD rules for current session..."
    apply_rule_idempotent nat POSTROUTING -s "$network" -o "$wan" -j MASQUERADE
    apply_rule_idempotent filter FORWARD -i "$bridge_name" -o "$wan" -s "$network" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    apply_rule_idempotent filter FORWARD -i "$wan" -o "$bridge_name" -d "$network" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    apply_rule_idempotent filter FORWARD -i "$bridge_name" -o "$bridge_name" -j ACCEPT
    
    # Bring up interface
    log_step "Bringing up $bridge_name..."
    if command -v ifreload &>/dev/null; then
        ifreload -a 2>/dev/null || true
    else
        if ! $br_exists; then
            ip link add name "$bridge_name" type bridge 2>/dev/null || true
        fi
        ip addr flush dev "$bridge_name" 2>/dev/null || true
        ip addr add "$bridge_ip" dev "$bridge_name" 2>/dev/null || true
        ip link set "$bridge_name" up
    fi
    
    # Auto-persist rules
    persist_rules "true"
    
    echo ""
    log_info "Private network $bridge_name configured successfully!"
    echo ""
    echo "VM Configuration:"
    echo "  Network device: $bridge_name"
    echo "  VM IP: any address in $network (e.g., ${network%/*} with last octet changed)"
    echo "  Gateway: $ip_only"
    echo "  DNS: 1.1.1.1 (or your preference)"
    echo ""
    echo "Note: NAT/FORWARD rules are auto-detected by the hardening script."
    echo "      Bridge config is in $INTERFACES_FILE (visible in Proxmox GUI)"
}

# =============================================================================
# Port Forwarding
# =============================================================================

add_port_forward() {
    echo ""
    echo -e "${BOLD}=== Add Port Forward ===${NC}"
    echo ""
    
    local wan=$(get_wan_bridge)
    local private_bridges=$(get_private_bridges)
    
    if [[ -z "$private_bridges" ]]; then
        log_error "No private bridges configured. Set up a private network first."
        return 1
    fi
    
    # Select target bridge
    echo "Available private bridges:"
    local i=1
    local br_array=()
    for br in $private_bridges; do
        local br_net=$(get_bridge_network "$br")
        echo "  $i) $br ($br_net)"
        br_array+=("$br")
        ((i++))
    done
    echo ""
    
    local target_br
    if [[ ${#br_array[@]} -eq 1 ]]; then
        target_br="${br_array[0]}"
        echo "Using: $target_br"
    else
        read -rp "Select bridge [1-${#br_array[@]}]: " br_choice
        if [[ ! "$br_choice" =~ ^[0-9]+$ ]] || [[ "$br_choice" -lt 1 ]] || [[ "$br_choice" -gt ${#br_array[@]} ]]; then
            log_error "Invalid selection"
            return 1
        fi
        target_br="${br_array[$((br_choice-1))]}"
    fi
    
    local br_net=$(get_bridge_network "$target_br")
    
    echo ""
    echo "Port forward configuration:"
    echo ""
    
    # Protocol
    read -rp "Protocol [tcp/udp, default: tcp]: " proto
    proto=${proto:-tcp}
    if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
        log_error "Invalid protocol. Use tcp or udp."
        return 1
    fi
    
    # External port
    read -rp "External port (on host): " ext_port
    if [[ ! "$ext_port" =~ ^[0-9]+$ ]] || [[ "$ext_port" -lt 1 ]] || [[ "$ext_port" -gt 65535 ]]; then
        log_error "Invalid port number."
        return 1
    fi
    
    # Check if port already forwarded
    if iptables -w -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport $ext_port.*DNAT"; then
        log_error "Port $ext_port is already forwarded!"
        echo "Remove the existing forward first, or use a different port."
        return 1
    fi
    
    # Also check custom.d
    if grep -q -- "--dport $ext_port.*DNAT" "$CUSTOM_DIR/nat.rules" 2>/dev/null; then
        log_error "Port $ext_port already has a pending forward in custom rules!"
        return 1
    fi
    
    # Destination IP
    read -rp "Destination VM IP: " dest_ip
    
    # Validate IP
    if ! validate_ip "$dest_ip"; then
        log_error "Invalid IP address."
        return 1
    fi
    
    # Validate destination is in the subnet (using Python)
    if ! ip_in_network "$dest_ip" "$br_net"; then
        log_warn "Destination IP $dest_ip is not in $target_br network ($br_net)"
        read -rp "Continue anyway? [y/N]: " cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # Destination port
    read -rp "Destination port (on VM) [$ext_port]: " dest_port
    dest_port=${dest_port:-$ext_port}
    if [[ ! "$dest_port" =~ ^[0-9]+$ ]] || [[ "$dest_port" -lt 1 ]] || [[ "$dest_port" -gt 65535 ]]; then
        log_error "Invalid port number."
        return 1
    fi
    
    echo ""
    echo "Summary:"
    echo "  $proto:$ext_port (public) → $dest_ip:$dest_port (VM on $target_br)"
    echo ""
    
    read -rp "Apply this port forward? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
    fi
    
    # Backup
    backup_configs
    
    # Setup custom.d
    setup_custom_dirs
    
    # Add DNAT rule
    local dnat_rule="-A PREROUTING -i $wan -p $proto --dport $ext_port -j DNAT --to-destination $dest_ip:$dest_port"
    log_step "Adding DNAT rule to $CUSTOM_DIR/nat.rules..."
    add_custom_rule "$CUSTOM_DIR/nat.rules" "$dnat_rule" "Port forward: $proto:$ext_port -> $dest_ip:$dest_port"
    
    # Add FORWARD rule (required for DNAT to work!)
    local fwd_rule="-A FORWARD -i $wan -o $target_br -p $proto -d $dest_ip --dport $dest_port -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT"
    log_step "Adding FORWARD rule to $CUSTOM_DIR/filter.rules..."
    add_custom_rule "$CUSTOM_DIR/filter.rules" "$fwd_rule" "Allow forward for $proto:$ext_port -> $dest_ip:$dest_port"
    
    # Apply immediately (idempotent)
    log_step "Applying rules immediately..."
    apply_rule_idempotent nat PREROUTING -i "$wan" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "$dest_ip:$dest_port"
    apply_rule_idempotent filter FORWARD -i "$wan" -o "$target_br" -p "$proto" -d "$dest_ip" --dport "$dest_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    
    # Auto-persist rules
    persist_rules "true"
    
    echo ""
    log_info "Port forward added: $proto:$ext_port → $dest_ip:$dest_port"
    echo ""
    echo "Don't forget to:"
    echo "  1. Allow port $dest_port in the VM's firewall (if any)"
    echo "  2. Ensure a service is listening on $dest_ip:$dest_port"
}

remove_port_forward() {
    echo ""
    echo -e "${BOLD}=== Remove Port Forward ===${NC}"
    echo ""
    
    # Collect all forwards (deduplicated)
    local forwards=$(get_port_forwards | sort -u)
    
    if [[ -z "$forwards" ]]; then
        log_warn "No port forwards configured."
        return 0
    fi
    
    echo "Current port forwards:"
    local i=1
    local fwd_array=()
    while read -r fwd; do
        local status=$(echo "$fwd" | cut -d: -f1)
        local proto=$(echo "$fwd" | cut -d: -f2)
        local rest=$(echo "$fwd" | cut -d: -f3-)
        local src_port=$(echo "$rest" | cut -d'-' -f1)
        local dest=$(echo "$rest" | cut -d'>' -f2)
        
        local status_str="[active]"
        [[ "$status" == "pending" ]] && status_str="[pending]"
        
        echo "  $i) $status_str $proto:$src_port → $dest"
        fwd_array+=("$proto:$src_port:$dest")
        ((i++))
    done <<< "$forwards"
    echo "  0) Cancel"
    echo ""
    
    read -rp "Select port forward to remove [0-$((i-1))]: " choice
    
    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        echo "Cancelled."
        return 0
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -ge "$i" ]]; then
        log_error "Invalid selection."
        return 1
    fi
    
    local selected="${fwd_array[$((choice-1))]}"
    local proto=$(echo "$selected" | cut -d: -f1)
    local ext_port=$(echo "$selected" | cut -d: -f2)
    local dest=$(echo "$selected" | cut -d: -f3)
    local dest_ip="${dest%:*}"
    local dest_port="${dest#*:}"
    
    echo ""
    echo "Will remove: $proto:$ext_port → $dest"
    read -rp "Confirm removal? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        return 0
    fi
    
    # Backup
    backup_configs
    
    local wan=$(get_wan_bridge)
    
    # Remove from iptables
    log_step "Removing from iptables..."
    remove_rule nat PREROUTING -i "$wan" -p "$proto" --dport "$ext_port" -j DNAT --to-destination "$dest"
    
    # Remove FORWARD rule
    for br in $(get_private_bridges); do
        remove_rule filter FORWARD -i "$wan" -o "$br" -p "$proto" -d "$dest_ip" --dport "$dest_port" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    done
    
    # Remove from custom.d files
    log_step "Removing from $CUSTOM_DIR/..."
    remove_custom_rule "$CUSTOM_DIR/nat.rules" "dport $ext_port.*$dest"
    remove_custom_rule "$CUSTOM_DIR/filter.rules" "dport $dest_port.*-d $dest_ip"
    
    # Auto-persist rules
    persist_rules "true"
    
    echo ""
    log_info "Port forward removed: $proto:$ext_port → $dest"
}

# =============================================================================
# Apply All Custom Rules (Integration with Hardening)
# =============================================================================

apply_custom_rules() {
    echo ""
    echo -e "${BOLD}=== Apply Custom Rules ===${NC}"
    echo ""
    
    if [[ -x "$HARDENING_SCRIPT" ]]; then
        log_info "Found hardening script at $HARDENING_SCRIPT"
        echo "This will regenerate and apply the full firewall ruleset including your custom rules."
        echo ""
        read -rp "Run hardening script --apply? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            "$HARDENING_SCRIPT" --apply
        fi
    else
        log_warn "Hardening script not found. Applying custom rules directly..."
        
        if [[ -f "$CUSTOM_DIR/nat.rules" ]]; then
            grep -v '^\s*#\|^\s*$' "$CUSTOM_DIR/nat.rules" 2>/dev/null | while read -r rule; do
                # Extract the rule parts after -A
                local chain=$(echo "$rule" | grep -oP '(?<=-A )\S+')
                local rest=$(echo "$rule" | sed 's/^-A [^ ]* //')
                apply_rule_idempotent nat "$chain" $rest
            done
        fi
        
        if [[ -f "$CUSTOM_DIR/filter.rules" ]]; then
            grep -v '^\s*#\|^\s*$' "$CUSTOM_DIR/filter.rules" 2>/dev/null | while read -r rule; do
                local chain=$(echo "$rule" | grep -oP '(?<=-A )\S+')
                local rest=$(echo "$rule" | sed 's/^-A [^ ]* //')
                apply_rule_idempotent filter "$chain" $rest
            done
        fi
        
        log_info "Custom rules applied."
    fi
}

# =============================================================================
# Manual Persistence
# =============================================================================

manual_persist() {
    echo ""
    echo -e "${BOLD}=== Save Rules for Persistence ===${NC}"
    echo ""
    
    persist_rules "false"
}

# =============================================================================
# Main Menu
# =============================================================================

show_menu() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Proxmox Private Network & Port Forward Manager v3.1        ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  1) View current status"
    echo "  2) Setup private network (NAT for VM internet)"
    echo "  3) Add port forward"
    echo "  4) Remove port forward"
    echo "  5) Apply all custom rules"
    echo "  6) Save rules (manual persistence)"
    echo "  7) Exit"
    echo ""
}

main() {
    check_root
    check_python
    
    while true; do
        show_menu
        read -rp "Select option [1-7]: " choice
        
        case "$choice" in
            1) show_status ;;
            2) setup_private_network ;;
            3) add_port_forward ;;
            4) remove_port_forward ;;
            5) apply_custom_rules ;;
            6) manual_persist ;;
            7) echo "Goodbye!"; exit 0 ;;
            *) log_error "Invalid option" ;;
        esac
        
        echo ""
        read -rp "Press Enter to continue..."
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi