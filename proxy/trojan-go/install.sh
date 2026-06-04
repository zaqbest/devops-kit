#!/usr/bin/env bash
# Trojan-Go Installation Script
# Part of devops-kit — proxy/trojan-go/install.sh

set -e

# ── Constants ─────────────────────────────────────────────────────────────────
TROJAN_GO_VERSION="v0.10.6"
INSTALL_DIR="/opt/trojan-go"
SERVICE_NAME="trojan-go"
TROJAN_PORT="8443"
DEFAULT_PASSWORD="rikei@1234"
DEFAULT_SNI_NAME="zaqproxy.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Load devops-kit lib ───────────────────────────────────────────────────────
if [ -f "${PROJECT_ROOT}/lib/log.sh" ]; then
    . "${PROJECT_ROOT}/lib/log.sh"
    . "${PROJECT_ROOT}/lib/os.sh"
    . "${PROJECT_ROOT}/lib/pkg.sh"
    . "${PROJECT_ROOT}/lib/privilege.sh"
    _LIB_LOADED=1
else
    # Minimal inline fallback for standalone use
    _LIB_LOADED=0
    log_info()  { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    die()       { log_error "$1"; exit "${2:-1}"; }
    require_root() {
        [ "${EUID:-$(id -u)}" -eq 0 ] || die "This script must be run as root."
    }
    detect_os() {
        # Minimal OS detection for standalone mode
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS_ID="${ID:-}"; OS_FAMILY="unknown"; PKG_MGR="unknown"
            case "$ID" in
                ubuntu|debian|linuxmint) OS_FAMILY="debian"; PKG_MGR="apt" ;;
                centos|rhel|rocky|almalinux|fedora)
                    OS_FAMILY="rhel"
                    PKG_MGR="yum"; command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
                    ;;
            esac
        fi
        case "$(uname -m)" in
            x86_64|amd64)   ARCH="amd64" ;;
            aarch64|arm64)  ARCH="arm64" ;;
            armv7l|armv6l)  ARCH="armv7" ;;
            i386|i686)      ARCH="x86"   ;;
            *)              ARCH="$(uname -m)" ;;
        esac
    }
    pkg_update() {
        case "${PKG_MGR:-unknown}" in
            apt) apt-get update -qq ;;
            dnf) dnf check-update -q || true ;;
            yum) yum check-update -q || true ;;
        esac
    }
    pkg_install_if_missing() {
        local pkg
        for pkg in "$@"; do
            if ! command -v "$pkg" >/dev/null 2>&1; then
                log_info "Installing: $pkg"
                case "${PKG_MGR:-unknown}" in
                    apt) apt-get install -y -q "$pkg" ;;
                    dnf) dnf install -y -q "$pkg" ;;
                    yum) yum install -y -q "$pkg" ;;
                    *) die "$pkg not found. Install it manually." ;;
                esac
            fi
        done
    }
fi

# Convenience aliases used throughout the script
log()   { log_info  "$*"; }
warn()  { log_warn  "$*"; }
error() { log_error "$*"; exit 1; }

# ── Trojan-Go specific arch mapping ──────────────────────────────────────────
# lib/os.sh uses: amd64 / arm64 / armv7 / x86
# trojan-go releases use: amd64 / arm / 386 / mips64 / mips64le
_resolve_trojan_arch() {
    case "$(uname -m)" in
        x86_64|amd64)              TROJAN_ARCH="amd64" ;;
        aarch64|arm64|armv7l|armv6l) TROJAN_ARCH="arm" ;;
        i386|i686)                 TROJAN_ARCH="386" ;;
        mips64)                    TROJAN_ARCH="mips64" ;;
        mips64le)                  TROJAN_ARCH="mips64le" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────

install_dependencies() {
    log "Installing dependencies (wget, curl, unzip, openssl)..."
    pkg_update
    pkg_install_if_missing wget curl unzip openssl
    log "Dependencies installed successfully"
}

download_trojan_go() {
    log "Downloading trojan-go ${TROJAN_GO_VERSION} (arch: $TROJAN_ARCH)..."

    local download_url="https://github.com/p4gefau1t/trojan-go/releases/download/${TROJAN_GO_VERSION}/trojan-go-linux-${TROJAN_ARCH}.zip"
    local temp_dir="/tmp/trojan-go-install"
    local zip_file="${temp_dir}/trojan-go.zip"

    mkdir -p "$temp_dir"
    log "Download URL: $download_url"

    local retry=0
    while [ $retry -lt 3 ]; do
        if wget -O "$zip_file" "$download_url"; then break; fi
        retry=$(( retry + 1 ))
        [ $retry -lt 3 ] && { warn "Download failed, retrying... ($retry/3)"; sleep 2; } \
                         || error "Failed to download trojan-go after 3 attempts"
    done

    [ -f "$zip_file" ] && [ -s "$zip_file" ] || error "Downloaded file is missing or empty"
    log "Download completed"
}

install_trojan_go() {
    log "Installing trojan-go to $INSTALL_DIR..."

    local temp_dir="/tmp/trojan-go-install"
    local zip_file="${temp_dir}/trojan-go.zip"

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        warn "Trojan-Go service is currently running"
        echo -n "Do you want to stop the service and continue? [y/N]: "
        read -r response
        case "$response" in
            [yY][eE][sS]|[yY])
                log "Stopping Trojan-Go service..."
                systemctl stop "$SERVICE_NAME"; sleep 2 ;;
            *) error "Installation cancelled by user" ;;
        esac
    fi

    if pgrep -x "trojan-go" >/dev/null; then
        warn "Killing running trojan-go process..."
        pkill -f "trojan-go"; sleep 2
        pgrep -x "trojan-go" >/dev/null && { pkill -9 -f "trojan-go"; sleep 1; }
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$temp_dir"
    unzip -o "$zip_file"

    local extracted_dir
    extracted_dir=$(find . -type d -name "*trojan-go*" | head -1)
    [ -z "$extracted_dir" ] && [ -f "trojan-go" ] && extracted_dir="."
    [ -n "$extracted_dir" ] || error "Could not find trojan-go binary in extracted files"

    local retry=0
    while [ $retry -lt 3 ]; do
        if cp -r "${extracted_dir}/"* "$INSTALL_DIR/" 2>/dev/null; then break; fi
        retry=$(( retry + 1 ))
        if [ $retry -lt 3 ]; then
            warn "Copy failed (attempt $retry/3), retrying..."
            pgrep -x "trojan-go" >/dev/null && pkill -9 -f "trojan-go"
            sleep 2
        else
            error "Failed to copy trojan-go files. Make sure no trojan-go process is running."
        fi
    done

    chmod +x "$INSTALL_DIR/trojan-go"
    rm -rf "$temp_dir"
    log "Installation completed"
}

set_directory_permissions() {
    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    if [ -d "$INSTALL_DIR/certs" ]; then
        chmod 750 "$INSTALL_DIR/certs"
        find "$INSTALL_DIR/certs" -name "*.crt" -exec chmod 644 {} \;
        find "$INSTALL_DIR/certs" -name "*.key" -exec chmod 600 {} \;
    fi
    [ -f "$INSTALL_DIR/config.json" ] && chmod 644 "$INSTALL_DIR/config.json"
    [ -f "$INSTALL_DIR/trojan-go"   ] && chmod +x  "$INSTALL_DIR/trojan-go"
    log "Directory permissions set"
}

copy_certificates() {
    local domain="$DEFAULT_SNI_NAME"
    local target_dir="$INSTALL_DIR/certs"

    log "Generating self-signed certificate for ${domain}..."
    mkdir -p "$target_dir"

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$target_dir/server.key" \
        -out    "$target_dir/server.crt" \
        -days   365 \
        -subj   "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:*.${domain}"

    chmod 644 "$target_dir/server.crt"
    chmod 600 "$target_dir/server.key"
    log "Certificate ready: $target_dir/server.crt"
}


create_config() {
    log "Creating configuration file..."
    local config_file="$INSTALL_DIR/config.json"

    cat > "$config_file" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${TROJAN_PORT},
    "remote_addr": "www.google.com",
    "remote_port": 443,
    "password": [
        "${DEFAULT_PASSWORD}"
    ],
    "ssl": {
        "verify": true,
        "verify_hostname": true,
        "cert": "${INSTALL_DIR}/certs/server.crt",
        "key": "${INSTALL_DIR}/certs/server.key",
        "sni": "${DEFAULT_SNI_NAME}"
    },
    "tcp": {
        "no_delay": true,
        "keep_alive": true,
        "prefer_ipv4": true
    },
    "router": {
        "enabled": true,
        "block": [
            "geoip:private"
        ],
        "geoip": "${INSTALL_DIR}/geoip.dat",
        "geosite": "${INSTALL_DIR}/geosite.dat"
    }
}
EOF
    chmod 644 "$config_file"
    log "Config: $config_file (port: $TROJAN_PORT, SNI: $DEFAULT_SNI_NAME)"
}

create_systemd_service() {
    log "Creating systemd service..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Trojan-Go Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/trojan-go -config ${INSTALL_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    log "Systemd service created and enabled"
}

create_sysv_service() {
    log "Creating SysV init script..."
    local init_script="/etc/init.d/${SERVICE_NAME}"
    cat > "$init_script" <<'EOF'
#!/bin/bash
# chkconfig: 35 99 99
# description: Trojan-Go Server
. /etc/rc.d/init.d/functions
USER="root"; DAEMON="trojan-go"; ROOT_DIR="/opt/trojan-go"
DAEMON_PATH="$ROOT_DIR/$DAEMON"; CONFIG_FILE="$ROOT_DIR/config.json"; PIDFILE="/var/run/${DAEMON}.pid"
start() {
    [ -f $PIDFILE ] && { echo "$DAEMON is already running."; return 1; }
    echo -n "Starting $DAEMON: "
    daemon --user="$USER" --pidfile="$PIDFILE" "$DAEMON_PATH" -config "$CONFIG_FILE" &
    echo $! > $PIDFILE; RETVAL=$?; echo
    [ $RETVAL -eq 0 ] && touch /var/lock/subsys/$DAEMON; return $RETVAL
}
stop() {
    [ ! -f $PIDFILE ] && { echo "$DAEMON is not running."; return 1; }
    echo -n "Shutting down $DAEMON: "
    kill -9 "$(cat $PIDFILE)"; rm -f $PIDFILE; RETVAL=$?; echo
    [ $RETVAL -eq 0 ] && rm -f /var/lock/subsys/$DAEMON; return $RETVAL
}
status() {
    if [ -f $PIDFILE ] && ps -p "$(cat $PIDFILE)" > /dev/null 2>&1; then
        echo "$DAEMON is running (pid $(cat $PIDFILE))"; return 0
    else
        echo "$DAEMON is not running"; return 3
    fi
}
case "$1" in start) start;; stop) stop;; status) status;; restart) stop; start;; *) echo "Usage: {start|stop|status|restart}"; exit 1;; esac
EOF
    chmod +x "$init_script"
    command -v chkconfig    >/dev/null 2>&1 && chkconfig --add "$SERVICE_NAME" && chkconfig "$SERVICE_NAME" on
    command -v update-rc.d  >/dev/null 2>&1 && update-rc.d "$SERVICE_NAME" defaults
    log "SysV init script created"
}

create_service() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        create_systemd_service
    else
        create_sysv_service
    fi
}

configure_firewall() {
    log "Configuring firewall for port $TROJAN_PORT/tcp..."
    local configured=false

    if command -v ufw >/dev/null 2>&1; then
        ! ufw status | grep -q "Status: active" && { log "Enabling UFW..."; echo "y" | ufw enable; }
        ufw allow "${TROJAN_PORT}/tcp" && ufw reload && configured=true \
            || warn "UFW rule failed"

    elif command -v firewall-cmd >/dev/null 2>&1; then
        systemctl is-active --quiet firewalld || { systemctl start firewalld; systemctl enable firewalld; }
        firewall-cmd --permanent --add-port="${TROJAN_PORT}/tcp" && firewall-cmd --reload && configured=true \
            || warn "firewalld rule failed"

    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$TROJAN_PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$TROJAN_PORT" -j ACCEPT
        # Persist rules across reboots
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v iptables-save >/dev/null 2>&1; then
            if [ -d /etc/sysconfig ]; then
                iptables-save > /etc/sysconfig/iptables
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
            fi
        fi
        configured=true
    fi

    if [ "$configured" = "false" ]; then
        warn "No firewall found. Manually allow port $TROJAN_PORT/tcp."
    else
        log "Firewall: port $TROJAN_PORT/tcp open"
    fi
}

start_services() {
    log "Starting Trojan-Go service..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$SERVICE_NAME" && sleep 2
        systemctl is-active --quiet "$SERVICE_NAME" \
            && log "Service is running" \
            || warn "Service may not be running. Check: journalctl -u $SERVICE_NAME -n 50"
    else
        service "$SERVICE_NAME" start 2>/dev/null \
            && log "Service started" \
            || warn "Service start failed"
    fi
}

show_system_status() {
    echo "================================================"
    echo "           Trojan-Go 系统状态"
    echo "================================================"
    echo
    echo -n "  服务状态: "
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && echo "[运行中]" || echo "[已停止]"
    echo -n "  二进制:   "
    [ -f "$INSTALL_DIR/trojan-go" ] && echo "[已安装] $INSTALL_DIR" || echo "[未安装]"
    echo -n "  SSL证书:  "
    [ -f "$INSTALL_DIR/certs/server.crt" ] && echo "[已配置] $INSTALL_DIR/certs/" || echo "[未配置]"
    echo "  监听端口: $TROJAN_PORT/tcp"
    echo "  配置文件: $INSTALL_DIR/config.json"
    echo "================================================"
    echo -n "按Enter键返回主菜单..."
    read -r
}

show_completion_info() {
    echo
    log "================================================"
    log "Trojan-Go 安装完成！"
    log "================================================"
    log "安装目录: $INSTALL_DIR"
    log "配置文件: $INSTALL_DIR/config.json"
    echo
    log "服务管理:"
    if command -v systemctl >/dev/null 2>&1; then
        log "  启动: systemctl start $SERVICE_NAME"
        log "  停止: systemctl stop $SERVICE_NAME"
        log "  状态: systemctl status $SERVICE_NAME"
        log "  日志: journalctl -u $SERVICE_NAME -f"
    else
        log "  启动/停止/状态: service $SERVICE_NAME {start|stop|status}"
    fi
    echo
    log "连接信息:"
    log "  端口:  $TROJAN_PORT"
    log "  密码:  $DEFAULT_PASSWORD"
    if [ -f "$INSTALL_DIR/certs/server.crt" ]; then
        local sni
        sni=$(openssl x509 -in "$INSTALL_DIR/certs/server.crt" -noout -subject -nameopt RFC2253 \
              2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
        log "  SNI:   ${sni:-$DEFAULT_SNI_NAME}"
    fi
    echo
    warn "重要提示:"
    warn "1. 请配置后端服务监听 8080 端口"
    warn "2. 确保防火墙已开放 $TROJAN_PORT/tcp"
    echo
    echo -n "按Enter键返回主菜单..."
    read -r
}

show_menu() {
    clear
    echo "================================================"
    echo "         Trojan-Go Installation Menu"
    echo "================================================"
    echo
    echo "  1) 一键完整安装 (推荐)"
    echo "  2) 仅安装依赖"
    echo "  3) 仅设置证书"
    echo "  4) 仅安装 Trojan-Go"
    echo "  5) 仅创建服务"
    echo "  6) 仅配置防火墙"
    echo "  7) 仅启动服务"
    echo "  8) 查看系统状态"
    echo "  0) 退出"
    echo
    echo "================================================"
}

get_user_choice() {
    while true; do
        echo -n "请选择操作 [0-8]: "
        read -r user_choice
        case $user_choice in
            0|1|2|3|4|5|6|7|8) return 0 ;;
            *) warn "请输入 0-8 之间的数字" ;;
        esac
    done
}

execute_steps() {
    local choice=$1
    case $choice in
        1)  require_root; detect_os; _resolve_trojan_arch
            install_dependencies; download_trojan_go; install_trojan_go
            copy_certificates; create_config
            set_directory_permissions; create_service; configure_firewall
            start_services; show_completion_info ;;
        2)  require_root; detect_os; _resolve_trojan_arch
            install_dependencies; log "依赖安装完成" ;;
        3)  copy_certificates; log "证书设置完成" ;;
        4)  require_root; detect_os; _resolve_trojan_arch
            download_trojan_go; install_trojan_go
            copy_certificates; create_config
            set_directory_permissions; log "Trojan-Go 安装完成" ;;
        5)  require_root; create_service; log "服务创建完成" ;;
        6)  require_root; configure_firewall; log "防火墙配置完成" ;;
        7)  require_root; start_services ;;
        8)  show_system_status ;;
        0)  log "退出"; exit 0 ;;
        *)  warn "无效选择"; return 1 ;;
    esac
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            --auto|-a)
                require_root
                detect_os
                _resolve_trojan_arch
                log "OS: $OS_PRETTY_NAME | Arch: $TROJAN_ARCH | PkgMgr: $PKG_MGR"
                install_dependencies
                download_trojan_go
                install_trojan_go
                copy_certificates
                create_config
                set_directory_permissions
                create_service
                configure_firewall
                start_services
                show_completion_info
                return 0 ;;
            --help|-h)
                echo "用法: $0 [--auto|-a] [--help|-h]"
                exit 0 ;;
            *)
                error "未知选项: $1" ;;
        esac
    fi

    while true; do
        show_menu
        get_user_choice
        local choice="$user_choice"
        echo
        execute_steps "$choice" || true
        [ "$choice" = "0" ] && break
        [ "$choice" != "8" ] && { echo; echo -n "按Enter键返回主菜单..."; read -r; }
    done
}

main "$@"
