#!/bin/bash
# =============================================================================
# Secure Debian Server v2
# =============================================================================
# Hardens a Debian host on OVH to be accessible only via WireGuard VPN.
# Public port rules are managed interactively from the menu — each port can
# be restricted to Cloudflare IPs, open to everyone, or localhost only.
#
# Post-hardening surface:
#   - <wg_port>/udp  : WireGuard entry point (world-open, always)
#   - Any ports you add via the port rules menu
#   - Everything else: VPN-gated
#
# Features:
#   - Guided OVH hardware firewall setup (outer layer)
#   - Interactive port rules menu (cloudflare / world / localhost per port)
#   - Live Cloudflare IP fetch from cloudflare.com/ips-v4 + ips-v6
#   - Systemd-based 120s rollback timer (survives SSH disconnects)
#   - nftables (Debian 13 native — not iptables, not UFW)
#   - IPv4 + IPv6 in a single inet table
#   - Atomic rule application via nft -f
#   - Persistence via nftables.service + /etc/nftables.conf
#   - UFW conflict detection and removal
#
# Usage:
#   ./secure-debian.sh           # Interactive menu
#   ./secure-debian.sh --apply   # Regenerate + apply from saved config (boot)
#   ./secure-debian.sh --cancel  # Cancel pending rollback timer
#   ./secure-debian.sh --status  # Show firewall status
#   ./secure-debian.sh --restore # Restore last backup
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
CONFIG_FILE="/etc/secure-debian.conf"
PORTS_FILE="/etc/secure-debian.ports"
NFT_RULES_FILE="/etc/nftables.conf"
SSH_HARDENING_CONFIG="/etc/ssh/sshd_config.d/99-hardening.conf"
ROLLBACK_UNIT="fw-rollback"
ROLLBACK_TIMEOUT=120

CF_V4_URL="https://www.cloudflare.com/ips-v4/"
CF_V6_URL="https://www.cloudflare.com/ips-v6/"

# Hardcoded fallback — used only when live fetch fails
CF_IPV4_FALLBACK=(
    173.245.48.0/20  103.21.244.0/22  103.22.200.0/22  103.31.4.0/22
    141.101.64.0/18  108.162.192.0/18 190.93.240.0/20  188.114.96.0/20
    197.234.240.0/22 198.41.128.0/17  162.158.0.0/15   104.16.0.0/13
    104.24.0.0/14    172.64.0.0/13    131.0.72.0/22
)
CF_IPV6_FALLBACK=(
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
    2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
)

# Runtime arrays populated by load_cloudflare_ips()
CF_IPV4=()
CF_IPV6=()

# Runtime array populated by load_port_rules()
PORT_RULES=()

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
    command -v nft  &>/dev/null || missing+=("nftables")
    command -v wg   &>/dev/null || missing+=("wireguard-tools")
    command -v curl &>/dev/null || missing+=("curl")

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
        echo "  UFW manages its own nftables rules. Running both causes"
        echo "  unpredictable firewall behaviour."
        echo ""
        read -rp "  Disable and remove UFW now? [Y/n]: " rm_ufw
        rm_ufw=${rm_ufw:-Y}
        if [[ "$rm_ufw" =~ ^[Yy]$ ]]; then
            ufw disable 2>/dev/null || true
            apt-get remove -y ufw > /dev/null 2>&1 || true
            log_info "UFW removed."
        else
            log_warn "Keeping UFW — rules may conflict."
        fi
    fi
}

# =============================================================================
# Cloudflare IP Management
# =============================================================================

# Fetches live Cloudflare IPs and populates CF_IPV4 / CF_IPV6.
# Falls back to hardcoded list on failure.
load_cloudflare_ips() {
    log_step "Fetching Cloudflare IP ranges..."

    local v4 v6
    v4=$(curl -sf --max-time 10 "$CF_V4_URL" 2>/dev/null | grep -oP '[\d.]+/\d+' || true)
    v6=$(curl -sf --max-time 10 "$CF_V6_URL" 2>/dev/null | grep -oP '[0-9a-f:]+/\d+' || true)

    if [[ -n "$v4" && -n "$v6" ]]; then
        mapfile -t CF_IPV4 <<< "$v4"
        mapfile -t CF_IPV6 <<< "$v6"
        log_info "Cloudflare IPs loaded: ${#CF_IPV4[@]} IPv4, ${#CF_IPV6[@]} IPv6"
    else
        log_warn "Live fetch failed — using hardcoded fallback ranges."
        CF_IPV4=("${CF_IPV4_FALLBACK[@]}")
        CF_IPV6=("${CF_IPV6_FALLBACK[@]}")
    fi
}

# Formats an array as a comma-separated nftables set element string
format_nft_set() {
    local -n _arr="$1"
    local out=""
    for elem in "${_arr[@]}"; do
        elem="${elem//[[:space:]]/}"
        [[ -z "$elem" ]] && continue
        out="${out}${elem}, "
    done
    echo "${out%, }"
}

# Returns 0 if any port rule uses cloudflare access
any_cloudflare_rules() {
    for r in "${PORT_RULES[@]}"; do
        [[ "$r" == *"|cloudflare|"* ]] && return 0
    done
    return 1
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

    # Method 2: scan /etc/wireguard/*.conf for ListenPort
    for conf in /etc/wireguard/*.conf; do
        [[ -f "$conf" ]] || continue
        local nic port
        nic=$(basename "$conf" .conf)
        port=$(grep -iP '^\s*ListenPort\s*=' "$conf" 2>/dev/null | grep -oP '\d+' | head -1 || true)
        if [[ -n "$port" ]]; then
            echo "${nic}:${port}"
            return
        fi
    done

    # Method 3: wg show (if a tunnel is already up)
    if command -v wg &>/dev/null; then
        local nic port
        nic=$(wg show interfaces 2>/dev/null | awk '{print $1}' | head -1 || true)
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

detect_wg_subnet() {
    local wg_nic="$1"
    ip -4 route show dev "$wg_nic" scope link 2>/dev/null | awk '{print $1}' | head -1
}

check_connected_via_vpn() {
    local wg_nic="$1"
    local client_ip="${SSH_CLIENT:-}"
    client_ip="${client_ip%% *}"
    [[ -z "$client_ip" ]] && return 1

    local wg_subnet
    wg_subnet=$(detect_wg_subnet "$wg_nic")
    [[ -z "$wg_subnet" ]] && return 1

    python3 -c "
import ipaddress, sys
try:
    net = ipaddress.ip_network('${wg_subnet}', strict=False)
    sys.exit(0 if ipaddress.ip_address('${client_ip}') in net else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# =============================================================================
# Port Rules (PORTS_FILE persistence)
# =============================================================================
# File format (pipe-separated):
#   PROTOCOL|PORT|ACCESS|DESCRIPTION
#   tcp|443|cloudflare|HTTPS via Cloudflare
#   udp|10000|world|Jitsi ICE WebRTC
#   tcp|9000|localhost|Internal dashboard

load_port_rules() {
    PORT_RULES=()
    [[ -f "$PORTS_FILE" ]] || return 0
    while IFS='|' read -r proto port access desc; do
        [[ "$proto" =~ ^#.*$|^[[:space:]]*$ ]] && continue
        [[ -z "$proto" || -z "$port" || -z "$access" ]] && continue
        PORT_RULES+=("${proto}|${port}|${access}|${desc}")
    done < "$PORTS_FILE"
}

save_port_rules() {
    {
        echo "# secure-debian port rules"
        echo "# Format: PROTOCOL|PORT|ACCESS|DESCRIPTION"
        echo "# ACCESS: cloudflare | world | localhost"
        for r in "${PORT_RULES[@]}"; do
            echo "$r"
        done
    } > "$PORTS_FILE"
}

port_rule_exists() {
    local proto="$1" port="$2"
    for r in "${PORT_RULES[@]}"; do
        local rp rport
        IFS='|' read -r rp rport _ _ <<< "$r"
        [[ "$rp" == "$proto" && "$rport" == "$port" ]] && return 0
    done
    return 1
}

add_port_rule() {
    echo ""
    echo -e "${BOLD}=== Add Port Rule ===${NC}"
    echo ""

    # Protocol
    read -rp "  Protocol [tcp/udp, default: tcp]: " proto
    proto=${proto:-tcp}
    if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
        log_error "Invalid protocol."; return 1
    fi

    # Port
    read -rp "  Port number: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "Invalid port number."; return 1
    fi

    if port_rule_exists "$proto" "$port"; then
        log_error "A rule for ${proto}/${port} already exists."
        return 1
    fi

    # Access type
    echo ""
    echo "  Who can reach this port?"
    echo "    1) Cloudflare IPs only  — for HTTPS proxied via Cloudflare"
    echo "    2) World open           — anyone (e.g. Jitsi ICE, game servers)"
    echo "    3) Localhost only       — only 127.0.0.1 (service must bind locally)"
    echo ""
    read -rp "  Choose [1-3]: " access_choice
    local access
    case "$access_choice" in
        1) access="cloudflare" ;;
        2) access="world"      ;;
        3) access="localhost"  ;;
        *) log_error "Invalid choice."; return 1 ;;
    esac

    # Description
    read -rp "  Short description (e.g. 'HTTPS via Cloudflare'): " desc
    desc=${desc:-"${proto}/${port}"}

    echo ""
    echo "  Rule: ${proto}/${port} — ${access} — ${desc}"
    read -rp "  Add this rule? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }

    PORT_RULES+=("${proto}|${port}|${access}|${desc}")
    save_port_rules
    log_info "Rule added."

    if [[ "$access" == "localhost" ]]; then
        echo ""
        log_warn "Localhost-only: ensure the service binds to 127.0.0.1, not 0.0.0.0."
        log_warn "The firewall loopback rule already allows all traffic on 127.0.0.1."
    fi
}

remove_port_rule() {
    echo ""
    echo -e "${BOLD}=== Remove Port Rule ===${NC}"
    echo ""

    if [[ ${#PORT_RULES[@]} -eq 0 ]]; then
        log_warn "No port rules configured."
        return 0
    fi

    local i=1
    for r in "${PORT_RULES[@]}"; do
        local proto port access desc
        IFS='|' read -r proto port access desc <<< "$r"
        printf "  %d) %s/%s  %-12s  %s\n" "$i" "$proto" "$port" "[$access]" "$desc"
        ((i++))
    done
    echo "  0) Cancel"
    echo ""
    read -rp "  Select rule to remove [0-$((i-1))]: " choice

    if [[ "$choice" == "0" || -z "$choice" ]]; then
        echo "Cancelled."; return 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice >= i )); then
        log_error "Invalid selection."; return 1
    fi

    local removed="${PORT_RULES[$((choice-1))]}"
    PORT_RULES=("${PORT_RULES[@]:0:$((choice-1))}" "${PORT_RULES[@]:$((choice))}")
    save_port_rules
    log_info "Removed: $removed"
}

list_port_rules() {
    echo ""
    echo -e "${CYAN}Configured port rules:${NC}"
    if [[ ${#PORT_RULES[@]} -eq 0 ]]; then
        echo "  None. Only WireGuard port is public."
        return 0
    fi
    echo ""
    printf "  %-6s %-7s %-12s %s\n" "Proto" "Port" "Access" "Description"
    printf "  %-6s %-7s %-12s %s\n" "-----" "----" "------" "-----------"
    for r in "${PORT_RULES[@]}"; do
        local proto port access desc
        IFS='|' read -r proto port access desc <<< "$r"
        local access_label
        case "$access" in
            cloudflare) access_label="${GREEN}cloudflare${NC}" ;;
            world)      access_label="${ORANGE}world-open${NC}" ;;
            localhost)  access_label="${CYAN}localhost${NC}"   ;;
            *)          access_label="$access" ;;
        esac
        printf "  %-6s %-7s " "$proto" "$port"
        echo -e "${access_label}   ${desc}"
    done
    echo ""
}

# =============================================================================
# SSH Hardening
# =============================================================================

# Returns a newline-separated list of non-root users in the sudo group
get_sudo_users() {
    getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^\s*$' || true
}

harden_ssh() {
    echo ""
    echo -e "${BOLD}=== SSH Hardening ===${NC}"
    echo ""

    # Show existing sudo users to help the user pick
    local sudo_users
    sudo_users=$(get_sudo_users)

    if [[ -n "$sudo_users" ]]; then
        echo -e "  ${CYAN}Sudo users detected on this system:${NC}"
        while read -r u; do
            local key_status=""
            if [[ -f "/home/${u}/.ssh/authorized_keys" ]] && [[ -s "/home/${u}/.ssh/authorized_keys" ]]; then
                key_status="${GREEN}(SSH key present)${NC}"
            else
                key_status="${RED}(no SSH key found)${NC}"
            fi
            echo -e "    - ${u}  ${key_status}"
        done <<< "$sudo_users"
    else
        log_warn "No users found in the sudo group."
    fi

    echo ""
    read -rp "  Admin username to keep SSH access for: " admin_user
    if [[ -z "$admin_user" ]]; then
        log_warn "Skipping SSH hardening."; return 0
    fi

    # Verify the user exists
    if ! id "$admin_user" &>/dev/null; then
        log_error "User '$admin_user' does not exist on this system."
        return 1
    fi

    # Verify sudo membership
    if ! groups "$admin_user" 2>/dev/null | grep -qw sudo; then
        log_warn "User '$admin_user' is not in the sudo group."
        read -rp "  Continue anyway? [y/N]: " cont
        [[ "$cont" =~ ^[Yy]$ ]] || return 0
    fi

    # Check for SSH keys — warn if missing, they will be locked out
    local key_file="/home/${admin_user}/.ssh/authorized_keys"
    if [[ ! -f "$key_file" ]] || [[ ! -s "$key_file" ]]; then
        echo ""
        log_warn "No SSH authorized_keys found for ${admin_user} at ${key_file}."
        log_warn "If you disable password auth without a key, you will be LOCKED OUT."
        echo ""
        read -rp "  Copy root's authorized_keys to ${admin_user}? [Y/n]: " copy_keys
        copy_keys=${copy_keys:-Y}
        if [[ "$copy_keys" =~ ^[Yy]$ ]]; then
            local home_dir
            home_dir=$(getent passwd "$admin_user" | cut -d: -f6)
            mkdir -p "${home_dir}/.ssh"
            cp /root/.ssh/authorized_keys "${home_dir}/.ssh/authorized_keys" 2>/dev/null || {
                log_error "Could not copy keys — /root/.ssh/authorized_keys missing."
                log_error "Add an SSH key for ${admin_user} manually before continuing."
                return 1
            }
            chown -R "${admin_user}:${admin_user}" "${home_dir}/.ssh"
            chmod 700 "${home_dir}/.ssh"
            chmod 600 "${home_dir}/.ssh/authorized_keys"
            log_info "SSH keys copied to ${home_dir}/.ssh/authorized_keys"
        else
            log_warn "Skipping key copy. Ensure keys are in place before disabling password auth."
        fi
    else
        log_info "SSH key found for ${admin_user}."
    fi

    echo ""
    echo "  Will apply to ${SSH_HARDENING_CONFIG}:"
    echo "    PermitRootLogin no"
    echo "    PasswordAuthentication no"
    echo "    PubkeyAuthentication yes"
    echo "    AllowUsers ${admin_user}"
    echo "    MaxAuthTries 3"
    echo "    LoginGraceTime 20"
    echo "    X11Forwarding no"
    echo ""
    echo "  Root password will also be locked (passwd -l root)."
    echo "  OVH KVM console access via SSH key is unaffected."
    echo ""
    echo -e "  ${ORANGE}IMPORTANT:${NC} Open a NEW terminal and verify you can SSH as"
    echo "  '${admin_user}' BEFORE confirming below."
    echo ""
    read -rp "  Apply SSH hardening? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_warn "SSH hardening skipped."; return 0; }

    # Write drop-in config (does not touch main sshd_config)
    mkdir -p "$(dirname "$SSH_HARDENING_CONFIG")"
    cat > "$SSH_HARDENING_CONFIG" << EOF
# Managed by secure-debian.sh — do not edit manually
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${admin_user}
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
EOF

    # Reload SSH (re-reads config without killing existing sessions)
    local ssh_svc="ssh"
    systemctl is-active --quiet sshd 2>/dev/null && ssh_svc="sshd"
    systemctl reload "$ssh_svc" 2>/dev/null || systemctl restart "$ssh_svc" 2>/dev/null || {
        log_error "Failed to reload SSH daemon."
        return 1
    }

    log_info "SSH hardening applied."
    echo ""
    echo -e "  ${GREEN}Root login disabled. Password auth disabled. AllowUsers: ${admin_user}.${NC}"
    echo ""
    echo "  Verify NOW in a new terminal:"
    echo "    ssh ${admin_user}@<server-ip>"
    echo "  Then confirm below."
    echo ""
    read -rp "  Confirmed SSH works as ${admin_user}? [y/N]: " verified
    if [[ ! "$verified" =~ ^[Yy]$ ]]; then
        log_warn "Reverting SSH hardening config..."
        rm -f "$SSH_HARDENING_CONFIG"
        systemctl reload "$ssh_svc" 2>/dev/null || true
        log_info "SSH config reverted."
    else
        log_info "SSH hardening confirmed and retained."
        passwd -l root > /dev/null 2>&1 \
            && log_info "Root password locked (KVM key-based console access unaffected)." \
            || log_warn "Could not lock root password — check manually with: passwd -l root"
    fi
}

# =============================================================================
# Sysctl Kernel Hardening
# =============================================================================

harden_sysctl() {
    echo ""
    echo -e "${BOLD}=== Kernel (sysctl) Hardening ===${NC}"
    echo ""

    local sysctl_file="/etc/sysctl.d/99-hardening.conf"

    if [[ -f "$sysctl_file" ]]; then
        log_warn "Already applied ($sysctl_file exists)."
        read -rp "  Reapply / overwrite? [y/N]: " reapply
        [[ "$reapply" =~ ^[Yy]$ ]] || return 0
    fi

    echo "  Will write $sysctl_file:"
    echo "    SYN flood protection (tcp_syncookies)"
    echo "    Reverse path filtering — anti-spoofing (rp_filter)"
    echo "    Block ICMP redirects (MITM routing attacks)"
    echo "    Block IP source routing"
    echo "    Ignore broadcast pings (smurf attacks)"
    echo "    TIME_WAIT assassination protection (tcp_rfc1337)"
    echo "    Hide kernel symbol addresses (kptr_restrict)"
    echo "    Restrict dmesg to root (dmesg_restrict)"
    echo "    Enforce ASLR (randomize_va_space)"
    echo "    Protected symlinks + hardlinks"
    echo ""
    read -rp "  Apply sysctl hardening? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_warn "Sysctl hardening skipped."; return 0; }

    cat > "$sysctl_file" << 'EOF'
# =============================================================================
# Kernel hardening — managed by secure-debian.sh
# =============================================================================

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Block ICMP redirects (used for MITM routing attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore broadcast pings (smurf attack amplification)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# TIME_WAIT assassination protection
net.ipv4.tcp_rfc1337 = 1

# Hide kernel symbol addresses from unprivileged users
kernel.kptr_restrict = 2

# Restrict dmesg to root
kernel.dmesg_restrict = 1

# ASLR — randomise memory address layout
kernel.randomize_va_space = 2

# Prevent symlink/hardlink TOCTOU attacks
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF

    # Apply immediately without reboot
    sysctl -p "$sysctl_file" > /dev/null 2>&1
    log_info "Sysctl hardening applied and persists across reboots."
}

# =============================================================================
# Automatic Security Upgrades
# =============================================================================

harden_autoupgrades() {
    echo ""
    echo -e "${BOLD}=== Automatic Security Upgrades ===${NC}"
    echo ""
    echo "  Installs and configures unattended-upgrades to automatically"
    echo "  apply security patches only — never dist-upgrades or new packages."
    echo "  Kernel updates that require a reboot will reboot at 03:00."
    echo ""
    read -rp "  Set up automatic security upgrades? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_warn "Auto upgrades skipped."; return 0; }

    if ! dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        log_step "Installing unattended-upgrades..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges \
            > /dev/null 2>&1
    fi

    # What to upgrade (security only)
    cat > "/etc/apt/apt.conf.d/50unattended-upgrades" << 'EOF'
// Managed by secure-debian.sh
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {};

// Remove unused dependencies after upgrade
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Auto-reboot if required (e.g. kernel update) — at 3am
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Uncomment to receive email on errors:
// Unattended-Upgrade::Mail "you@example.com";
// Unattended-Upgrade::MailReport "on-change";
EOF

    # Schedule (daily update check + upgrade)
    cat > "/etc/apt/apt.conf.d/20auto-upgrades" << 'EOF'
// Managed by secure-debian.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable unattended-upgrades > /dev/null 2>&1 || true
    systemctl restart unattended-upgrades > /dev/null 2>&1 || true

    log_info "Automatic security upgrades configured."
    echo ""
    echo "  Security patches will auto-apply daily."
    echo "  Reboot-required updates trigger a reboot at 03:00."
    echo "  To change reboot time: edit /etc/apt/apt.conf.d/50unattended-upgrades"
}

# =============================================================================
# OVH Hardware Firewall Guide
# =============================================================================

show_ovh_guide() {
    local wg_port="$1"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║               STEP 1 — OVH Hardware Firewall Setup                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  The OVH hardware firewall sits at the network level, before traffic"
    echo "  reaches your NIC. It is your outer safety net — configure it first."
    echo ""
    echo -e "  ${CYAN}Where:${NC}"
    echo "    OVH Control Panel → Bare Metal Cloud → IP → ⚙ → Firewall"
    echo "    (Enable the firewall on your server IP if not already on)"
    echo ""
    echo -e "  ${CYAN}Rules to add — minimum to get started:${NC}"
    echo ""
    printf "  %-4s %-8s %-10s %-10s %-14s %s\n" "Pri" "Action" "Protocol" "Source" "Dest Port" "Purpose"
    printf "  %-4s %-8s %-10s %-10s %-14s %s\n" "---" "------" "--------" "------" "---------" "-------"
    printf "  %-4s %-8s %-10s %-10s %-14s %s\n" "0"   "PERMIT" "TCP"      "any"    "established" "Return traffic"
    printf "  %-4s %-8s %-10s %-10s %-14s %s\n" "1"   "PERMIT" "UDP"      "any"    "${wg_port}"  "WireGuard VPN"
    printf "  %-4s %-8s %-10s %-10s %-14s %s\n" "19"  "DENY"   "any"      "any"    "any"         "Block everything else"
    echo ""
    echo -e "  ${ORANGE}Note:${NC} Add rules for your public ports (443, 10000, etc.) to OVH after"
    echo "  adding them via this script's port rules menu. OVH's firewall is your"
    echo "  outer layer — it should mirror what this script opens."
    echo "  SSH (22) is intentionally absent — it will be VPN-gated."
    echo ""
}

# =============================================================================
# nftables Rule Generation
# =============================================================================

generate_ruleset() {
    local wg_nic="$1"
    local wg_port="$2"

    # CF arrays must be pre-populated by the caller before this function is
    # invoked — load_cloudflare_ips() prints to stdout and must NOT be called
    # inside a command substitution or its log lines corrupt the ruleset.
    local cf_sets=""
    if any_cloudflare_rules; then
        local cf_v4_elems cf_v6_elems
        cf_v4_elems=$(format_nft_set CF_IPV4)
        cf_v6_elems=$(format_nft_set CF_IPV6)
        cf_sets="
    set cf_ipv4 {
        type ipv4_addr
        flags interval
        elements = { ${cf_v4_elems} }
    }

    set cf_ipv6 {
        type ipv6_addr
        flags interval
        elements = { ${cf_v6_elems} }
    }
"
    fi

    # Build port rules fragment for input chain
    local port_fragment=""
    if [[ ${#PORT_RULES[@]} -gt 0 ]]; then
        port_fragment="        # --- Public port rules ---"$'\n'
        for r in "${PORT_RULES[@]}"; do
            local proto port access desc
            IFS='|' read -r proto port access desc <<< "$r"
            case "$access" in
                cloudflare)
                    port_fragment+="        ${proto} dport ${port} ip  saddr @cf_ipv4 accept comment \"${desc} (Cloudflare IPv4)\""$'\n'
                    port_fragment+="        ${proto} dport ${port} ip6 saddr @cf_ipv6 accept comment \"${desc} (Cloudflare IPv6)\""$'\n'
                    ;;
                world)
                    port_fragment+="        ${proto} dport ${port} accept comment \"${desc}\""$'\n'
                    ;;
                localhost)
                    port_fragment+="        iif \"lo\" ${proto} dport ${port} accept comment \"${desc} (localhost)\""$'\n'
                    ;;
            esac
        done
        port_fragment+=""
    fi

    cat << RULESET
#!/usr/sbin/nft -f
# =============================================================================
# nftables ruleset — generated by secure-debian.sh
# $(date)
# WireGuard: ${wg_nic} port ${wg_port}/udp
# Port rules: ${#PORT_RULES[@]}
# =============================================================================

flush ruleset

table inet filter {
${cf_sets}
    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state invalid drop
        ct state { established, related } accept

        ip protocol icmp icmp type {
            echo-request, echo-reply,
            destination-unreachable, time-exceeded, parameter-problem
        } accept

        ip6 nexthdr icmpv6 icmpv6 type {
            echo-request, echo-reply,
            destination-unreachable, packet-too-big,
            time-exceeded, parameter-problem,
            nd-router-solicit, nd-router-advert,
            nd-neighbor-solicit, nd-neighbor-advert
        } accept

        # WireGuard — world-open, sole public admin entry point
        udp dport ${wg_port} accept comment "WireGuard VPN"

${port_fragment}
        # WireGuard interface — fully trusted (SSH, all management)
        iif "${wg_nic}" accept comment "WireGuard clients"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
RULESET
}

# =============================================================================
# Apply and Persist
# =============================================================================

apply_ruleset() {
    local ruleset="$1"
    local tmp
    tmp=$(mktemp /tmp/nft-rules-XXXXXX.nft)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    echo "$ruleset" > "$tmp"
    log_step "Applying nftables rules atomically..."
    if ! nft -f "$tmp"; then
        log_error "nftables rule application failed — rules unchanged."
        return 1
    fi
    log_info "Rules applied."
}

persist_ruleset() {
    local ruleset="$1"

    log_step "Writing to $NFT_RULES_FILE..."
    echo "$ruleset" > "$NFT_RULES_FILE"

    log_step "Enabling nftables.service..."
    systemctl enable nftables > /dev/null 2>&1 || true
    systemctl reload-or-restart nftables > /dev/null 2>&1 || true

    log_info "Rules persisted — loaded at boot via nftables.service"
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
    log_step "Restoring from $backup..."
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
                nft -f '${backup}' 2>/dev/null \
                    && echo 'ROLLBACK: Done.' >&2 \
                    || { echo 'ROLLBACK: nft restore failed — flushing to open state.' >&2; nft flush ruleset 2>/dev/null || true; }
            else
                echo 'ROLLBACK: No backup found — flushing ruleset to open state.' >&2
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
# Config Persistence (WG params only)
# =============================================================================

save_config() {
    local wg_nic="$1"
    local wg_port="$2"
    cat > "$CONFIG_FILE" << EOF
# secure-debian configuration — generated $(date)
WG_NIC=${wg_nic}
WG_PORT=${wg_port}
EOF
    log_info "Config saved to $CONFIG_FILE"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# =============================================================================
# Status
# =============================================================================

show_status() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    Firewall Status                            ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}Network:${NC}"
    echo "  WAN interface : $(detect_wan_interface || echo 'unknown')"

    local wg_pair
    wg_pair=$(detect_wireguard)
    if [[ -n "$wg_pair" ]]; then
        local wg_nic="${wg_pair%%:*}"
        local wg_port="${wg_pair##*:}"
        echo "  WireGuard     : ${wg_nic} port ${wg_port}/udp"
        if ip link show "$wg_nic" &>/dev/null; then
            local peers
            peers=$(wg show "$wg_nic" peers 2>/dev/null | wc -l || true)
            echo "  WG status     : UP (${peers} peer(s))"
        else
            echo -e "  WG status     : ${RED}DOWN${NC}"
        fi
    else
        echo -e "  WireGuard     : ${RED}not detected${NC}"
    fi
    echo ""

    echo -e "${CYAN}nftables:${NC}"
    if nft list tables 2>/dev/null | grep -q "inet filter"; then
        local policy
        policy=$(nft list chain inet filter input 2>/dev/null | grep -oP 'policy \K\w+' || true)
        echo -e "  Ruleset       : ${GREEN}loaded${NC} (INPUT policy: ${policy:-unknown})"
    else
        echo -e "  Ruleset       : ${ORANGE}not loaded${NC}"
    fi
    if [[ -f "$NFT_RULES_FILE" ]]; then
        echo -e "  Persistence   : ${GREEN}$NFT_RULES_FILE exists${NC}"
    else
        echo -e "  Persistence   : ${RED}missing — won't survive reboot${NC}"
    fi
    systemctl is-enabled --quiet nftables 2>/dev/null \
        && echo -e "  Boot service  : ${GREEN}enabled${NC}" \
        || echo -e "  Boot service  : ${RED}disabled${NC}"
    echo ""

    echo -e "${CYAN}SSH hardening (${SSH_HARDENING_CONFIG}):${NC}"
    if [[ -f "$SSH_HARDENING_CONFIG" ]]; then
        local root_login pw_auth
        root_login=$(grep -oP '(?<=PermitRootLogin )\S+' "$SSH_HARDENING_CONFIG" 2>/dev/null || echo "unset")
        pw_auth=$(grep -oP '(?<=PasswordAuthentication )\S+' "$SSH_HARDENING_CONFIG" 2>/dev/null || echo "unset")
        echo -e "  Drop-in       : ${GREEN}present${NC}"
        echo "  PermitRootLogin     : ${root_login}"
        echo "  PasswordAuthentication : ${pw_auth}"
        echo ""
        echo -e "  ${CYAN}Sudo users:${NC}"
        local sudo_users
        sudo_users=$(get_sudo_users)
        if [[ -n "$sudo_users" ]]; then
            while read -r u; do
                local key_note=""
                [[ -f "/home/${u}/.ssh/authorized_keys" ]] && [[ -s "/home/${u}/.ssh/authorized_keys" ]] \
                    && key_note="${GREEN}key ok${NC}" || key_note="${RED}no key${NC}"
                printf "    - %-20s " "$u"
                echo -e "$key_note"
            done <<< "$sudo_users"
        else
            echo "    None found in sudo group"
        fi
    else
        echo -e "  ${ORANGE}Not applied — root login and password auth may still be enabled${NC}"
    fi
    echo ""

    echo -e "${CYAN}Sysctl hardening:${NC}"
    if [[ -f "/etc/sysctl.d/99-hardening.conf" ]]; then
        echo -e "  ${GREEN}Applied${NC} (/etc/sysctl.d/99-hardening.conf)"
    else
        echo -e "  ${ORANGE}Not applied${NC}"
    fi
    echo ""

    echo -e "${CYAN}Automatic security upgrades:${NC}"
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        systemctl is-active --quiet unattended-upgrades 2>/dev/null \
            && echo -e "  unattended-upgrades: ${GREEN}active${NC}" \
            || echo -e "  unattended-upgrades: ${ORANGE}installed but not running${NC}"
    else
        echo -e "  ${ORANGE}Not installed${NC}"
    fi
    echo ""

    list_port_rules

    echo -e "${CYAN}Rollback timer:${NC}"
    if is_rollback_pending; then
        echo -e "  ${ORANGE}PENDING — run '$0 --cancel' to make rules permanent${NC}"
    else
        echo "  None"
    fi
    echo ""
}

# =============================================================================
# Port Rules Menu
# =============================================================================

port_rules_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}=== Public Port Rules ===${NC}"
        list_port_rules

        echo "  a) Add rule"
        echo "  r) Remove rule"
        echo "  b) Back"
        echo ""
        read -rp "  Choose: " choice

        case "$choice" in
            a|A) add_port_rule || true ;;
            r|R) remove_port_rule || true ;;
            b|B) return 0 ;;
            *) log_error "Invalid option." ;;
        esac
    done
}

# =============================================================================
# Apply Rules (reapply with current port rules, no wizard)
# =============================================================================

reapply_rules() {
    if ! load_config; then
        log_error "No saved config — run setup first."
        return 1
    fi

    load_port_rules
    any_cloudflare_rules && load_cloudflare_ips
    local ruleset
    ruleset=$(generate_ruleset "${WG_NIC}" "${WG_PORT}")

    echo ""
    echo "=== Ruleset to apply ==="
    echo "$ruleset"
    echo "========================"
    echo ""

    read -rp "Apply with ${ROLLBACK_TIMEOUT}s auto-rollback? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }

    backup_rules
    schedule_rollback "$ROLLBACK_TIMEOUT"
    if ! apply_ruleset "$ruleset"; then
        log_warn "Cancelling rollback timer — old rules remain in place."
        cancel_rollback
        return 0
    fi

    echo ""
    echo -e "${GREEN}Rules applied. Verify in a NEW terminal, then run: $0 --cancel${NC}"
    echo ""
    read -rp "Verified? Cancel rollback and persist? [y/N]: " verified
    if [[ "$verified" =~ ^[Yy]$ ]]; then
        cancel_rollback
        persist_ruleset "$ruleset"
        log_info "Rules persisted."
    else
        log_warn "Rules NOT persisted. Rollback in ~${ROLLBACK_TIMEOUT}s."
    fi
}

# =============================================================================
# First-Run Setup Wizard
# =============================================================================

run_setup_wizard() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║             Secure Debian Server — First Run Setup            ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"

    check_os
    check_dependencies
    check_ufw_conflict

    # Detect WireGuard
    echo ""
    local wg_pair
    wg_pair=$(detect_wireguard)

    local wg_nic wg_port
    if [[ -n "$wg_pair" ]]; then
        wg_nic="${wg_pair%%:*}"
        wg_port="${wg_pair##*:}"
        log_info "WireGuard detected: ${wg_nic} port ${wg_port}/udp"
    else
        log_warn "WireGuard not detected automatically."
        echo ""
        read -rp "  Enter WireGuard interface (e.g. wg0), or blank to exit: " wg_nic
        [[ -z "$wg_nic" ]] && { echo "Exiting."; exit 0; }
        read -rp "  Enter WireGuard listen port: " wg_port
        [[ "$wg_port" =~ ^[0-9]+$ ]] || { log_error "Invalid port."; exit 1; }
    fi

    # SSH hardening (disable root login, password auth, AllowUsers, lock root password)
    harden_ssh

    # Sysctl kernel hardening
    harden_sysctl

    # Automatic security upgrades
    harden_autoupgrades

    # OVH guide
    show_ovh_guide "$wg_port"
    read -rp "Have you configured the OVH hardware firewall? [y/N]: " ovh_done
    if [[ ! "$ovh_done" =~ ^[Yy]$ ]]; then
        log_warn "Set up the OVH firewall first — it is your outer safety net."
        echo "  Re-run this script afterwards."
        exit 0
    fi

    # VPN connection check
    echo ""
    if check_connected_via_vpn "$wg_nic"; then
        log_info "Confirmed: current session is over WireGuard."
    else
        log_warn "Current session does NOT appear to be over WireGuard."
        echo ""
        echo "  After hardening, only WireGuard clients reach SSH."
        echo "  The ${ROLLBACK_TIMEOUT}s rollback timer is your safety net — but"
        echo "  connecting via VPN BEFORE applying is strongly recommended."
        echo ""
    fi

    # Save config now (port rules come later via menu)
    save_config "$wg_nic" "$wg_port"

    # Generate and show ruleset (no port rules yet)
    load_port_rules
    any_cloudflare_rules && load_cloudflare_ips
    local ruleset
    ruleset=$(generate_ruleset "$wg_nic" "$wg_port")

    echo ""
    echo "=== Generated ruleset ==="
    echo "$ruleset"
    echo "========================="
    echo ""

    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: This will block ALL non-VPN inbound access.          ║${NC}"
    echo -e "${RED}║  Only port ${wg_port}/udp (WireGuard) will remain public.         ║${NC}"
    echo -e "${RED}║  A ${ROLLBACK_TIMEOUT}s systemd rollback timer will be armed.              ║${NC}"
    echo -e "${RED}║  Test in a NEW terminal, then run: $0 --cancel     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Apply rules with ${ROLLBACK_TIMEOUT}s auto-rollback? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    backup_rules
    schedule_rollback "$ROLLBACK_TIMEOUT"
    if ! apply_ruleset "$ruleset"; then
        log_warn "Cancelling rollback timer — old rules remain in place."
        cancel_rollback
        echo "  Fix the issue and re-run the wizard."
        return 0
    fi

    echo ""
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Rules applied. You have ${ROLLBACK_TIMEOUT}s before auto-rollback.${NC}"
    echo -e "${GREEN}  Open a NEW terminal and verify SSH works over WireGuard.${NC}"
    echo -e "${GREEN}  Then run: $0 --cancel${NC}"
    echo -e "${GREEN}═════════════════════════════════════════════════════════════════${NC}"
    echo ""

    read -rp "Verified? Cancel rollback and persist? [y/N]: " verified
    if [[ "$verified" =~ ^[Yy]$ ]]; then
        cancel_rollback
        persist_ruleset "$ruleset"
        echo ""
        log_info "Hardening complete. WireGuard port ${wg_port}/udp is the only public port."
        echo ""
        echo "  Use the port rules menu to open 443, Jitsi ICE, or any other ports."
    else
        log_warn "Rules NOT persisted. Rollback will fire in ~${ROLLBACK_TIMEOUT}s."
    fi
}

# =============================================================================
# Main Menu
# =============================================================================

main_menu() {
    load_port_rules

    while true; do
        echo ""
        echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║                Secure Debian Server v2                        ║${NC}"
        echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1) Status"
        echo "  2) Manage public port rules"
        echo "  3) Reapply rules (apply changes to port rules)"
        echo "  4) SSH hardening (root login, password auth, AllowUsers)"
        echo "  5) Sysctl kernel hardening"
        echo "  6) Automatic security upgrades"
        echo "  7) Cancel rollback timer"
        echo "  8) Restore last backup"
        echo "  9) Re-run setup wizard"
        echo "  0) Exit"
        echo ""
        read -rp "  Choose [0-9]: " choice

        case "$choice" in
            1) show_status ;;
            2) port_rules_menu; load_port_rules ;;
            3) reapply_rules || true ;;
            4) harden_ssh || true ;;
            5) harden_sysctl ;;
            6) harden_autoupgrades ;;
            7) cancel_rollback ;;
            8) restore_backup || true ;;
            9) run_setup_wizard || true ;;
            0) echo "Goodbye."; exit 0 ;;
            *) log_error "Invalid option." ;;
        esac

        echo ""
        read -rp "  Press Enter to continue..."
    done
}

# =============================================================================
# --apply (boot-time: regenerate from saved config + current port rules)
# =============================================================================

apply_from_config() {
    if ! load_config; then
        log_error "No saved config at $CONFIG_FILE — run interactive setup first."
        exit 1
    fi

    load_port_rules
    any_cloudflare_rules && load_cloudflare_ips
    log_step "Regenerating ruleset (WG: ${WG_NIC}:${WG_PORT}, ${#PORT_RULES[@]} port rule(s))..."
    local ruleset
    ruleset=$(generate_ruleset "${WG_NIC}" "${WG_PORT}")
    if ! apply_ruleset "$ruleset"; then
        log_error "Boot-time rule application failed."
        exit 1
    fi
    log_info "Rules applied from saved config."
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
        load_port_rules
        show_status
        ;;
    --restore)
        restore_backup
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "  (none)     Interactive menu"
        echo "  --apply    Apply rules from saved config + port rules (use at boot)"
        echo "  --cancel   Cancel pending rollback timer"
        echo "  --status   Show firewall and WireGuard status"
        echo "  --restore  Restore last backup"
        echo "  --help     This help text"
        ;;
    "")
        if load_config 2>/dev/null; then
            main_menu
        else
            run_setup_wizard
            main_menu
        fi
        ;;
    *)
        log_error "Unknown option: $1"
        exit 1
        ;;
esac
