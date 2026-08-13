#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh - Standalone VPS post-install initialization
# -----------------------------------------------------------------------------
#  1. Detect OS (type/version/arch/pkgmgr)
#  2. Install essential packages (curl, wget, git, vim, tar, unzip, ...)
#  3. Create appropriately sized swap based on RAM
#  4. Set locale (en_US.UTF-8) + timezone Asia/Shanghai (UTC+8)
#  5. Disable firewall (ufw/firewalld/iptables/nftables)
#  6. Apply high-concurrency kernel/ulimit tuning
#  7. Install SSH public keys into root's authorized_keys
#  8. (Optional) Install Docker via https://get.docker.com  [asked interactively]
#
#  Usage:
#     sudo bash bootstrap.sh                        # interactive menu (pick steps)
#     sudo bash bootstrap.sh --all                  # run all steps 1..8 (old behavior)
#     sudo bash bootstrap.sh --menu                 # force menu even with --yes
#     sudo bash bootstrap.sh --steps=1,3,5          # run only these steps
#     sudo bash bootstrap.sh --steps=2-6            # run a range of steps
#     sudo bash bootstrap.sh --yes                  # non-interactive; runs --all; docker OFF unless --with-docker
#     sudo bash bootstrap.sh --yes --with-docker    # non-interactive + install docker
#     sudo bash bootstrap.sh --no-docker            # never install docker (skip prompt)
#     sudo bash bootstrap.sh --dry-run              # preview only
#
#  Steps:
#     1) Detect OS      2) Essential pkgs  3) Swap        4) TZ + Locale
#     5) Firewall off   6) sysctl+ulimit   7) SSH keys    8) Docker (optional)
#
#  Supports: Debian/Ubuntu/CentOS/RHEL/Rocky/AlmaLinux/Fedora/Alpine
# =============================================================================
set -euo pipefail

# sshkey-per-server-user
SSH_PUBLIC_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBhbRKu8KG/LuX8i7BZd6s+qU7E1leMkNTGowCISjpK4"
)
TIMEZONE="Asia/Shanghai"
LOCALE="en_US.UTF-8"
SWAP_MAX_GB=8
LOG_FILE="/var/log/devops-bootstrap.log"

ASSUME_YES=0; DRY_RUN=0; DOCKER_MODE=ask   # ask | yes | no
RUN_MODE=auto                              # auto | menu | all | steps
STEPS_ARG=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes)      ASSUME_YES=1 ;;
        -n|--dry-run)  DRY_RUN=1 ;;
        --with-docker) DOCKER_MODE=yes ;;
        --no-docker)   DOCKER_MODE=no ;;
        --menu)        RUN_MODE=menu ;;
        --all)         RUN_MODE=all ;;
        --steps=*)     RUN_MODE=steps; STEPS_ARG="${arg#--steps=}" ;;
        -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
        *)             echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
if [ -t 1 ]; then
    _CR=$'\033[0;31m'; _CG=$'\033[0;32m'; _CY=$'\033[0;33m'
    _CC=$'\033[0;36m'; _CB=$'\033[1m';    _CM=$'\033[0;35m'; _C0=$'\033[0m'
else
    _CR=; _CG=; _CY=; _CC=; _CB=; _CM=; _C0=
fi

_log() {
    local lvl=$1 col=$2; shift 2
    printf '%s[%s]%s %s\n' "$col" "$lvl" "$_C0" "$*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] [%s] %s\n' "$(_ts)" "$lvl" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
log()  { _log 'INFO ' "$_CG" "$@"; }
warn() { _log 'WARN ' "$_CY" "$@" >&2; }
err()  { _log 'ERROR' "$_CR" "$@" >&2; }
dry()  { _log 'DRY  ' "$_CM" "$@"; }
die()  { err "$@"; exit 1; }
step() { echo; printf '%s%s==> %s%s\n' "$_CC" "$_CB" "$*" "$_C0"; }
run()  { if [ "$DRY_RUN" = 1 ]; then dry "$*"; else eval "$@"; fi; }

# Try to open the controlling terminal so `read` still works when the script
# itself is being piped in via `bash <(curl ...)` or `curl ... | bash`.
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    HAS_TTY=1
else
    HAS_TTY=0
fi

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ "$HAS_TTY" != 1 ]; then
        log "Non-interactive (no tty): auto-answer YES for: $1"
        return 0
    fi
    local r
    read -rp "$1 [Y/n] " r </dev/tty || { warn "read failed, assuming YES"; return 0; }
    [[ -z $r || $r =~ ^[Yy] ]]
}

[ "$(id -u)" -eq 0 ] || die "Must run as root (use sudo)"
trap 'err "Failed at line $LINENO (exit=$?)"' ERR

banner() {
    cat <<'BEOF'

  ============================================================
      Server Bootstrap - bootstrap.sh (self-contained)
   OS | Swap | TZ | Locale | Firewall | Sysctl | SSH-Keys
  ============================================================
BEOF
}

is_container() {
    [ -f /.dockerenv ] && return 0
    grep -qE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# ---- STEP 1: OS detection ---------------------------------------------------
detect_os() {
    step "1/8  Detect operating system"
    OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""; OS_FAMILY="unknown"; PKG_MGR="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"; OS_VERSION_ID="${VERSION_ID:-}"; OS_PRETTY="${PRETTY_NAME:-$ID}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID=rhel; OS_PRETTY=$(cat /etc/redhat-release)
    elif [ -f /etc/alpine-release ]; then
        OS_ID=alpine; OS_PRETTY="Alpine $(cat /etc/alpine-release)"
    fi
    case "$OS_ID" in
        ubuntu|debian|linuxmint|raspbian|kali|pop) OS_FAMILY=debian; PKG_MGR=apt ;;
        centos|rhel|rocky|almalinux|fedora|ol|amzn)
            OS_FAMILY=rhel
            if command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; else PKG_MGR=yum; fi ;;
        alpine) OS_FAMILY=alpine; PKG_MGR=apk ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        armv7l|armv7)  ARCH=armv7 ;;
        i386|i686)     ARCH=x86 ;;
        *)             ARCH=$(uname -m) ;;
    esac
    if [ -d /run/systemd/system ] || pidof systemd >/dev/null 2>&1; then
        INIT_SYSTEM=systemd
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM=openrc
    else
        INIT_SYSTEM=sysv
    fi
    log "OS:      $OS_PRETTY"
    log "ID:      $OS_ID  (family: $OS_FAMILY)"
    log "Version: $OS_VERSION_ID"
    log "Arch:    $ARCH   Kernel: $(uname -r)"
    log "PkgMgr:  $PKG_MGR   Init: $INIT_SYSTEM"
    log "Host:    $(hostname 2>/dev/null || echo unknown)"
    if [ "$OS_FAMILY" = unknown ]; then
        die "Unsupported system: $OS_PRETTY"
    fi
    return 0
}

pkg_update() {
    case "$PKG_MGR" in
        apt) run "DEBIAN_FRONTEND=noninteractive apt-get update -y" ;;
        dnf) run "dnf makecache -y || true" ;;
        yum) run "yum makecache -y || true" ;;
        apk) run "apk update" ;;
    esac
}
pkg_install() {
    local pkgs=$*; [ -z "$pkgs" ] && return 0
    case "$PKG_MGR" in
        apt) run "DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs" ;;
        dnf) run "dnf install -y $pkgs" ;;
        yum) run "yum install -y $pkgs" ;;
        apk) run "apk add --no-cache $pkgs" ;;
    esac
}

# ---- STEP 2: Install essential packages ------------------------------------
install_essentials() {
    step "2/8  Install essential packages"
    local common="curl wget git vim tar unzip ca-certificates"
    local extra=""
    case "$OS_FAMILY" in
        debian)
            extra="gnupg lsb-release apt-transport-https dnsutils net-tools htop"
            ;;
        rhel)
            extra="bind-utils net-tools htop"
            ;;
        alpine)
            extra="bash sudo openssh openssl bind-tools htop coreutils procps"
            ;;
    esac
    log "Installing: $common $extra"
    pkg_install $common $extra || warn "some essential packages failed to install (continuing)"
    log "Essential packages installed"
}

# ---- STEP 3: Swap -----------------------------------------------------------
configure_swap() {
    step "3/8  Configure swap based on RAM"
    if is_container; then warn "Container env, skipping swap"; return 0; fi

    local ram_kb ram_mb ram_gb swap_gb swap_mb
    ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    ram_mb=$(( ram_kb / 1024 ))
    ram_gb=$(( (ram_mb + 1023) / 1024 ))
    if   [ "$ram_gb" -le 2 ]; then swap_gb=$(( ram_gb * 2 ))
    elif [ "$ram_gb" -le 8 ]; then swap_gb=$ram_gb
    else                            swap_gb=$(( ram_gb / 2 ))
    fi
    [ "$swap_gb" -gt "$SWAP_MAX_GB" ] && swap_gb=$SWAP_MAX_GB
    swap_mb=$(( swap_gb * 1024 ))
    [ "$swap_mb" -lt 512 ] && swap_mb=512
    log "RAM: ${ram_mb}MB (~${ram_gb}GB), target swap: ${swap_mb}MB"

    if [ -f /swapfile ] && swapon --show 2>/dev/null | grep -q '/swapfile'; then
        local cur_mb
        cur_mb=$(swapon --show --bytes --noheadings 2>/dev/null | awk '/\/swapfile/ {printf "%d",$3/1024/1024}')
        if [ -n "$cur_mb" ] && [ "$cur_mb" -ge $(( swap_mb - 64 )) ]; then
            log "Existing ${cur_mb}MB swap OK, skip"; return 0
        fi
        log "Recreate swapfile: ${cur_mb:-?}MB -> ${swap_mb}MB"
        run "swapoff /swapfile || true"
        run "rm -f /swapfile"
    fi

    local avail_mb fs_type
    avail_mb=$(df -BM / | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
    [ "$avail_mb" -lt $(( swap_mb + 500 )) ] && warn "Low disk (${avail_mb}MB), attempting anyway"
    fs_type=$(df -T / | awk 'NR==2 {print $2}')

    if [ "$DRY_RUN" = 1 ]; then
        dry "Create /swapfile ${swap_mb}MB (fs=$fs_type)"; return 0
    fi

    if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        warn "fallocate failed, falling back to dd"
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
    fi
    [ "$fs_type" = btrfs ] && chattr +C /swapfile 2>/dev/null || true
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap active: $(free -h | awk '/Swap:/ {print $2}')"
}

# ---- STEP 4: Timezone + Locale ---------------------------------------------
configure_time_locale() {
    step "4/8  Configure timezone ($TIMEZONE) + locale ($LOCALE)"

    # tzdata
    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        log "Installing tzdata"
        case "$OS_FAMILY" in
            debian) pkg_install tzdata ;;
            rhel)   pkg_install tzdata ;;
            alpine) pkg_install tzdata ;;
        esac
    fi

    if command -v timedatectl >/dev/null 2>&1 && [ "$INIT_SYSTEM" = systemd ]; then
        run "timedatectl set-timezone '$TIMEZONE'"
        run "timedatectl set-ntp true 2>/dev/null || true"
    else
        run "ln -sf '/usr/share/zoneinfo/$TIMEZONE' /etc/localtime"
        run "echo '$TIMEZONE' > /etc/timezone"
    fi

    log "Timezone now: $(date '+%Z %z  %Y-%m-%d %H:%M:%S')"

    # locale
    case "$OS_FAMILY" in
        debian)
            pkg_install locales
            if [ "$DRY_RUN" != 1 ]; then
                if ! grep -q "^$LOCALE" /etc/locale.gen 2>/dev/null; then
                    sed -i "s/^# *\($LOCALE\)/\1/" /etc/locale.gen 2>/dev/null || \
                        echo "$LOCALE UTF-8" >> /etc/locale.gen
                fi
                locale-gen >/dev/null 2>&1 || true
                update-locale LANG="$LOCALE" LC_ALL="$LOCALE" >/dev/null 2>&1 || true
            fi
            ;;
        rhel)
            pkg_install glibc-langpack-en 2>/dev/null || pkg_install glibc-locale-source glibc-common || true
            if command -v localectl >/dev/null 2>&1; then
                run "localectl set-locale LANG='$LOCALE' || true"
            else
                run "echo 'LANG=$LOCALE' > /etc/locale.conf"
            fi
            ;;
        alpine)
            pkg_install musl-locales musl-locales-lang 2>/dev/null || true
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/locale.sh <<LOCEOF
export LANG=$LOCALE
export LC_ALL=$LOCALE
LOCEOF
            ;;
    esac
    log "Locale set: $LOCALE"
}

# ---- STEP 5: Disable firewall ----------------------------------------------
disable_firewall() {
    step "5/8  Disable firewall (all)"

    # ufw
    if command -v ufw >/dev/null 2>&1; then
        log "Disabling ufw"
        run "ufw --force disable || true"
        run "systemctl disable --now ufw 2>/dev/null || true"
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q firewalld; then
        log "Disabling firewalld"
        run "systemctl stop firewalld 2>/dev/null || true"
        run "systemctl disable firewalld 2>/dev/null || true"
        run "systemctl mask firewalld 2>/dev/null || true"
    fi

    # nftables
    if command -v nft >/dev/null 2>&1; then
        log "Flushing nftables"
        run "nft flush ruleset 2>/dev/null || true"
        run "systemctl stop nftables 2>/dev/null || true"
        run "systemctl disable nftables 2>/dev/null || true"
    fi

    # iptables policies + flush
    if command -v iptables >/dev/null 2>&1; then
        log "Flushing iptables rules & setting policies to ACCEPT"
        for chain in INPUT OUTPUT FORWARD; do
            run "iptables -P $chain ACCEPT 2>/dev/null || true"
        done
        run "iptables -F 2>/dev/null || true"
        run "iptables -X 2>/dev/null || true"
        run "iptables -t nat -F 2>/dev/null || true"
        run "iptables -t nat -X 2>/dev/null || true"
        run "iptables -t mangle -F 2>/dev/null || true"
        run "iptables -t mangle -X 2>/dev/null || true"
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        for chain in INPUT OUTPUT FORWARD; do
            run "ip6tables -P $chain ACCEPT 2>/dev/null || true"
        done
        run "ip6tables -F 2>/dev/null || true"
        run "ip6tables -X 2>/dev/null || true"
    fi

    # SELinux (permissive; do not enforce)
    if command -v setenforce >/dev/null 2>&1; then
        run "setenforce 0 2>/dev/null || true"
        [ -f /etc/selinux/config ] && run "sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config"
    fi

    log "Firewall disabled"
}

# ---- STEP 6: High-concurrency sysctl + ulimit ------------------------------
apply_sysctl_ulimit() {
    step "6/8  Apply high-concurrency sysctl + ulimit"

    if [ "$DRY_RUN" = 1 ]; then
        dry "Write /etc/sysctl.d/99-devops-bootstrap.conf and /etc/security/limits.d/99-devops-bootstrap.conf"
        return 0
    fi

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-devops-bootstrap.conf <<'SYSCTLEOF'
# ============ bootstrap.sh — high-concurrency tuning ============
# --- File descriptors ---
fs.file-max = 2097152
fs.nr_open = 2097152

# --- Network: connection queues ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_max_tw_buckets = 1048576

# --- Network: TCP tuning ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384

# --- Ports & buffers ---
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- BBR / congestion control (kernel-dependent) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Security hardening ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# --- IPv6 (leave enabled; do not disable) ---
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# --- Memory / swap ---
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.min_free_kbytes = 65536

# --- Inotify / process ---
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
kernel.pid_max = 4194304
kernel.threads-max = 4194304
SYSCTLEOF

    log "Applying /etc/sysctl.d/99-devops-bootstrap.conf"
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-devops-bootstrap.conf >/dev/null 2>&1 || true

    # ---- ulimit / limits.conf ----
    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-devops-bootstrap.conf <<'LIMITSEOF'
# bootstrap.sh — high-concurrency ulimit
*       soft    nofile      1048576
*       hard    nofile      1048576
*       soft    nproc       unlimited
*       hard    nproc       unlimited
*       soft    memlock     unlimited
*       hard    memlock     unlimited
*       soft    stack       65536
*       hard    stack       65536
root    soft    nofile      1048576
root    hard    nofile      1048576
root    soft    nproc       unlimited
root    hard    nproc       unlimited
LIMITSEOF

    # PAM: ensure pam_limits is loaded
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive /etc/pam.d/login /etc/pam.d/sshd; do
        if [ -f "$pam_file" ] && ! grep -q '^session.*pam_limits.so' "$pam_file"; then
            echo 'session required pam_limits.so' >> "$pam_file"
        fi
    done

    # systemd defaults
    if [ "$INIT_SYSTEM" = systemd ]; then
        mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
        cat > /etc/systemd/system.conf.d/99-devops-bootstrap.conf <<'SYSDEOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
SYSDEOF
        cp /etc/systemd/system.conf.d/99-devops-bootstrap.conf /etc/systemd/user.conf.d/99-devops-bootstrap.conf
        systemctl daemon-reexec 2>/dev/null || true
    fi

    # /etc/profile.d
    cat > /etc/profile.d/99-devops-bootstrap-ulimit.sh <<'PROFEOF'
# bootstrap.sh: raise ulimit for interactive shells
ulimit -n 1048576 2>/dev/null || true
ulimit -u unlimited 2>/dev/null || true
PROFEOF
    chmod 644 /etc/profile.d/99-devops-bootstrap-ulimit.sh

    log "sysctl + ulimit applied"
}

# ---- STEP 7: SSH public keys -----------------------------------------------
install_ssh_keys() {
    step "7/8  Install SSH public keys for root"

    if [ "${#SSH_PUBLIC_KEYS[@]}" -eq 0 ]; then
        warn "No SSH_PUBLIC_KEYS defined, skip"; return 0
    fi

    local ssh_dir=/root/.ssh
    local auth=$ssh_dir/authorized_keys

    if [ "$DRY_RUN" = 1 ]; then
        dry "Would append ${#SSH_PUBLIC_KEYS[@]} key(s) to $auth"
        for k in "${SSH_PUBLIC_KEYS[@]}"; do dry "  $k"; done
        return 0
    fi

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth"
    chmod 600 "$auth"

    local added=0
    for key in "${SSH_PUBLIC_KEYS[@]}"; do
        key="$(echo "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "$key" ] && continue
        # match by the middle key body to dedupe regardless of trailing comment
        local body
        body=$(awk '{print $2}' <<<"$key")
        if [ -n "$body" ] && grep -qF "$body" "$auth" 2>/dev/null; then
            log "Key already present: ${key:0:40}..."
        else
            echo "$key" >> "$auth"
            log "Added key: ${key:0:40}..."
            added=$(( added + 1 ))
        fi
    done
    chown -R root:root "$ssh_dir"
    log "SSH keys installed ($added new)"

    # Make sure sshd allows pubkey auth (does not disable password / does not touch port)
    if [ -f /etc/ssh/sshd_config ]; then
        if ! grep -qE '^\s*PubkeyAuthentication\s+yes' /etc/ssh/sshd_config; then
            if grep -qE '^\s*#?\s*PubkeyAuthentication' /etc/ssh/sshd_config; then
                sed -i 's|^\s*#\?\s*PubkeyAuthentication.*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
            else
                echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
            fi
            if sshd -t 2>/dev/null; then
                systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
                    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || true
                log "Enabled PubkeyAuthentication and reloaded sshd"
            else
                warn "sshd -t failed; leaving sshd_config unchanged from reload"
            fi
        fi
    fi
}

# ---- STEP 8: (Optional) Install Docker -------------------------------------
install_docker() {
    step "8/8  Install Docker (optional)"

    if command -v docker >/dev/null 2>&1; then
        log "Docker already installed: $(docker --version 2>/dev/null | head -1)"
        return 0
    fi

    # Decide install or not
    local do_install=0
    case "$DOCKER_MODE" in
        yes)
            do_install=1
            log "--with-docker specified: proceeding to install Docker"
            ;;
        no)
            log "--no-docker specified: skipping Docker installation"
            return 0
            ;;
        ask)
            if [ "$ASSUME_YES" = 1 ] || [ "$HAS_TTY" != 1 ]; then
                log "Non-interactive (no tty or --yes): skipping Docker (default off)"
                log "  Tip: re-run with 'bootstrap.sh --yes --with-docker' to install"
                return 0
            fi
            echo
            printf '%s%s' "$_CY" "$_CB"
            cat <<'DOCKEREOF'
  +----------------------------------------------------------+
  |  Optional: Install Docker Engine (CE)                    |
  |                                                          |
  |    * Uses the official installer: https://get.docker.com |
  |    * Installs docker-ce + docker CLI + compose plugin    |
  |    * Enables & starts docker.service (systemd) or        |
  |      docker/openrc (Alpine)                              |
  |                                                          |
  |  Default: NO (safe to skip if you don't need containers) |
  +----------------------------------------------------------+
DOCKEREOF
            printf '%s' "$_C0"
            local r=""
            read -rp "Install Docker now? [y/N] " r </dev/tty || r=""
            if [[ "$r" =~ ^[Yy] ]]; then
                do_install=1
            else
                log "User declined; skipping Docker"
                return 0
            fi
            ;;
    esac
    [ "$do_install" = 1 ] || return 0

    # Alpine: use apk (get.docker.com does not officially support Alpine)
    if [ "$OS_FAMILY" = alpine ]; then
        log "Installing Docker via apk (Alpine)"
        pkg_install docker docker-cli-compose
        if [ "$DRY_RUN" != 1 ]; then
            rc-update add docker default 2>/dev/null || true
            rc-service docker start 2>/dev/null || true
        fi
        log "Docker: $(docker --version 2>/dev/null || echo '(installed, may need re-login)')"
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        dry "Would download & run: curl -fsSL https://get.docker.com | sh"
        dry "Would enable + start docker.service"
        return 0
    fi

    # ---- Strategy A: official installer (get.docker.com) ----
    log "Attempt 1: official installer at https://get.docker.com ..."
    if curl -fsSL --connect-timeout 10 --max-time 60 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        if sh /tmp/get-docker.sh; then
            rm -f /tmp/get-docker.sh
        else
            warn "get-docker.sh failed to install"
            rm -f /tmp/get-docker.sh
        fi
    else
        warn "get.docker.com unreachable (network blocked?), will try distro repo"
    fi

    # ---- Strategy B: distro package repo (works behind GFW & no network to get.docker.com) ----
    if ! command -v docker >/dev/null 2>&1; then
        log "Attempt 2: distro package repository"
        case "$OS_FAMILY" in
            debian)
                # docker.io is in Debian/Ubuntu main repos, docker-compose-plugin usually not
                pkg_install docker.io docker-compose-plugin 2>/dev/null || \
                    pkg_install docker.io docker-compose 2>/dev/null || \
                    pkg_install docker.io || \
                    warn "distro-installed docker.io failed"
                ;;
            rhel)
                pkg_install docker docker-compose 2>/dev/null || \
                    pkg_install docker || \
                    warn "distro-installed docker failed"
                ;;
        esac
    fi

    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl enable --now docker 2>/dev/null || true
    fi

    if command -v docker >/dev/null 2>&1; then
        log "Docker installed: $(docker --version)"
        log "Compose plugin:  $(docker compose version 2>/dev/null || echo 'not detected')"
    else
        warn "Docker installation failed via all methods (get.docker.com + distro repo)"
        warn "Manual install: https://docs.docker.com/engine/install/"
    fi
}
# ---- Final summary ---------------------------------------------------------
print_summary() {
    echo
    printf '%s%s================ SUMMARY ================%s\n' "$_CC" "$_CB" "$_C0"
    printf '  %-14s %s\n' "OS:"        "$OS_PRETTY"
    printf '  %-14s %s\n' "Arch:"      "$ARCH"
    printf '  %-14s %s\n' "PkgMgr:"    "$PKG_MGR"
    printf '  %-14s %s\n' "Init:"      "$INIT_SYSTEM"
    printf '  %-14s %s\n' "Hostname:"  "$(hostname 2>/dev/null || echo -)"
    printf '  %-14s %s\n' "Timezone:"  "$(date '+%Z %z  %Y-%m-%d %H:%M:%S')"
    printf '  %-14s %s\n' "Locale:"    "${LANG:-$LOCALE}"
    printf '  %-14s %s\n' "Swap:"      "$(free -h 2>/dev/null | awk '/Swap:/ {print $2}')"
    printf '  %-14s %s\n' "Swappiness:" "$(sysctl -n vm.swappiness 2>/dev/null || echo -)"
    printf '  %-14s %s\n' "somaxconn:" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo -)"
    printf '  %-14s %s\n' "file-max:"  "$(sysctl -n fs.file-max 2>/dev/null || echo -)"
    printf '  %-14s %s\n' "nofile:"    "$(ulimit -n 2>/dev/null || echo -)"
    if command -v docker >/dev/null 2>&1; then
        printf '  %-14s %s\n' "Docker:"    "$(docker --version 2>/dev/null || echo installed)"
    else
        printf '  %-14s %s\n' "Docker:"    "not installed"
    fi
    printf '  %-14s %s\n' "Log file:"  "$LOG_FILE"
    echo

    log "All done. Reboot recommended for full effect: sudo reboot"
}

# ---- Step dispatcher --------------------------------------------------------
# Map step number -> function name + short label
STEP_FUNCS=(
    ""                          # index 0 unused so users see 1-based numbers
    "install_essentials"
    "configure_swap"
    "configure_time_locale"
    "disable_firewall"
    "apply_sysctl_ulimit"
    "install_ssh_keys"
    "install_docker"
)
STEP_LABELS=(
    ""
    "Install essential packages (curl/wget/git/vim/…)"
    "Configure swap based on RAM"
    "Set timezone ($TIMEZONE) + locale ($LOCALE)"
    "Disable firewall (ufw/firewalld/iptables/nftables)"
    "High-concurrency sysctl + ulimit"
    "Install SSH public keys for root"
    "Install Docker (optional)"
)
STEP_COUNT=7   # step 1 = detect_os, always run before others; 1..7 above are steps 2..8

# Parse "1,3,5" / "2-6" / "1,3-5,8" into a sorted-unique list of ints (1..8)
# Step 1 = OS detect (always forced on), steps 2..8 map to STEP_FUNCS[1..7].
parse_steps() {
    local spec=$1 out="" part a b i
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | tr -d '[:space:]')
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            [ "$a" -gt "$b" ] && { i=$a; a=$b; b=$i; }
            for ((i=a; i<=b; i++)); do out+="$i "; done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            out+="$part "
        else
            die "Invalid step token: '$part' (use e.g. 1,3-5,8)"
        fi
    done
    # sort unique, keep in range 1..8
    echo "$out" | tr ' ' '\n' | awk 'NF && $1>=1 && $1<=8' | sort -nu | tr '\n' ' '
}

run_step() {
    # $1 = step number 1..8
    local n=$1
    case "$n" in
        1) detect_os ;;
        2|3|4|5|6|7|8)
            local fn="${STEP_FUNCS[$((n-1))]}"
            "$fn"
            ;;
        *) warn "Unknown step: $n" ;;
    esac
}

# Interactive menu: user picks steps
show_menu() {
    echo
    printf '%s%s  Select steps to run (space or comma separated, e.g. 1,3-5)%s\n' "$_CC" "$_CB" "$_C0"
    printf '  %s0)%s  Run ALL steps (1..8)\n' "$_CG" "$_C0"
    printf '  %s1)%s  Detect OS  %s[always runs]%s\n' "$_CG" "$_C0" "$_CY" "$_C0"
    local i
    for i in $(seq 2 8); do
        printf '  %s%d)%s  %s\n' "$_CG" "$i" "$_C0" "${STEP_LABELS[$((i-1))]}"
    done
    printf '  %sq)%s  Quit\n' "$_CG" "$_C0"
    echo
}

pick_steps_interactive() {
    if [ "$HAS_TTY" != 1 ]; then
        die "Menu requested but no TTY available. Use --steps=... or --all instead."
    fi
    local sel
    while :; do
        show_menu
        read -rp "Your choice: " sel </dev/tty || die "read failed"
        sel=$(echo "$sel" | tr -d '[:space:]')
        case "$sel" in
            q|Q|quit|exit) log "User quit"; exit 0 ;;
            0|all|ALL|"") STEPS_TO_RUN="1 2 3 4 5 6 7 8"; return 0 ;;
            *)
                local parsed
                parsed=$(parse_steps "$sel" 2>/dev/null) || { warn "Invalid input, try again"; continue; }
                if [ -z "$parsed" ]; then
                    warn "No valid step numbers, try again"; continue
                fi
                # Always include step 1 (OS detect) since other steps depend on it
                STEPS_TO_RUN=$(echo "1 $parsed" | tr ' ' '\n' | sort -nu | tr '\n' ' ')
                return 0
                ;;
        esac
    done
}

# ---- Main -------------------------------------------------------------------
main() {
    banner

    # Resolve which mode we're in
    if [ "$RUN_MODE" = auto ]; then
        # auto: menu if interactive TTY and no --yes; else run all
        if [ "$ASSUME_YES" = 1 ] || [ "$HAS_TTY" != 1 ]; then
            RUN_MODE=all
        else
            RUN_MODE=menu
        fi
    fi

    STEPS_TO_RUN=""
    case "$RUN_MODE" in
        all)
            STEPS_TO_RUN="1 2 3 4 5 6 7 8"
            ;;
        steps)
            [ -n "$STEPS_ARG" ] || die "--steps requires a value, e.g. --steps=1,3-5"
            STEPS_TO_RUN=$(parse_steps "$STEPS_ARG")
            [ -n "$STEPS_TO_RUN" ] || die "No valid steps parsed from: $STEPS_ARG"
            # Ensure step 1 always runs first (needed for OS_FAMILY/PKG_MGR etc.)
            STEPS_TO_RUN=$(echo "1 $STEPS_TO_RUN" | tr ' ' '\n' | sort -nu | tr '\n' ' ')
            ;;
        menu)
            pick_steps_interactive
            ;;
    esac

    log "Steps to run: $STEPS_TO_RUN"
    confirm "Continue with these steps?" || die "Aborted by user"

    # detect_os is a no-op-safe prerequisite for anything using PKG_MGR / OS_FAMILY
    local need_pkg_update=0 s
    for s in $STEPS_TO_RUN; do
        case "$s" in 2|4|8) need_pkg_update=1 ;; esac
    done

    for s in $STEPS_TO_RUN; do
        if [ "$s" = 1 ]; then
            run_step 1
            if [ "$need_pkg_update" = 1 ]; then
                pkg_update || warn "package index update failed (continuing)"
            fi
        else
            run_step "$s"
        fi
    done

    print_summary
}

main "$@"
