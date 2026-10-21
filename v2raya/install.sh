#!/usr/bin/env bash

# Install v2rayA on Debian, Ubuntu, and CentOS.
# The actual binary download and checksum verification are delegated to the
# official v2rayA installer so this script always follows the latest release.

set -Eeuo pipefail

readonly OFFICIAL_INSTALLER_URL="https://raw.githubusercontent.com/v2rayA/v2rayA-installer/main/installer.sh"

log() {
    printf '[v2rayA] %s\n' "$*"
}

error() {
    printf '[v2rayA] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install or update v2rayA using the official v2rayA installer.

Options:
  --no-start    Install/update v2rayA but do not start its service
  --no-enable   Do not enable v2rayA to start at boot
  -h, --help    Show this help

Examples:
  sudo ./install.sh
  sudo ./install.sh --no-start
EOF
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || error "please run this script as root, for example: sudo $0"
}

detect_os() {
    [[ -r /etc/os-release ]] || error "/etc/os-release was not found"
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            PACKAGE_MANAGER="apt-get"
            ;;
        centos)
            if command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER="dnf"
            else
                PACKAGE_MANAGER="yum"
            fi
            ;;
        *)
            error "unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}} (supported: Debian, Ubuntu, CentOS)"
            ;;
    esac

    [[ "$(uname -s)" == "Linux" ]] || error "this script only supports Linux"
    log "detected ${PRETTY_NAME:-$ID}"
}

install_dependencies() {
    local packages=(curl unzip ca-certificates)

    log "installing required packages: ${packages[*]}"
    case "$PACKAGE_MANAGER" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "${packages[@]}"
            ;;
        dnf|yum)
            "$PACKAGE_MANAGER" install -y "${packages[@]}"
            ;;
    esac
}

install_v2raya() {
    local installer
    installer="$(mktemp)"
    trap 'rm -f "$installer"' RETURN

    log "downloading the official v2rayA installer"
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        "$OFFICIAL_INSTALLER_URL" -o "$installer"
    chmod 700 "$installer"

    log "running the official v2rayA installer"
    "$installer"
}

configure_service() {
    command -v systemctl >/dev/null 2>&1 || {
        log "systemd was not found; v2rayA was installed, but the service was not configured"
        return
    }

    systemctl daemon-reload

    if [[ "$START_SERVICE" == true ]]; then
        systemctl restart v2raya
        log "v2rayA service started"
    else
        log "skipped starting v2rayA (--no-start)"
    fi

    if [[ "$ENABLE_SERVICE" == true ]]; then
        systemctl enable v2raya
        log "v2rayA service enabled at boot"
    else
        systemctl disable v2raya >/dev/null 2>&1 || true
        log "skipped enabling v2rayA at boot (--no-enable)"
    fi
}

main() {
    local start_service=true
    local enable_service=true

    while (($#)); do
        case "$1" in
            --no-start) start_service=false ;;
            --no-enable) enable_service=false ;;
            -h|--help) usage; return 0 ;;
            *) error "unknown option: $1 (use --help for usage)" ;;
        esac
        shift
    done

    START_SERVICE="$start_service"
    ENABLE_SERVICE="$enable_service"

    require_root
    detect_os
    install_dependencies
    install_v2raya
    configure_service

    log "installation completed"
    log "web interface: http://<server-ip>:2017"
    log "configuration directory: /usr/local/etc/v2raya"
}

main "$@"