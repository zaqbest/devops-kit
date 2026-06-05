#!/usr/bin/env bash
# Module 13: Docker CE + Docker Compose installation
PHASE_KEY="DOCKER_INSTALLED"

_docker_debian() {
    pkg_install ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${OS_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    pkg_update
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_docker_rhel() {
    pkg_install yum-utils
    if command -v dnf &>/dev/null; then
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    else
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_docker_alpine() {
    pkg_install docker
    rc-update add docker default
}

main() {
    # ── Docker + Compose ──────────────────────────────────────────────────────
    if command -v docker &>/dev/null; then
        log_info "Docker already installed: $(docker --version)"
    else
        log_info "Installing Docker CE (OS: ${OS_ID}, family: ${OS_FAMILY})..."
        case "$OS_FAMILY" in
            debian) _docker_debian ;;
            rhel)   _docker_rhel ;;
            alpine) _docker_alpine ;;
            *)      log_info "Unsupported OS family: ${OS_FAMILY}"; return 1 ;;
        esac
        service_enable_start docker
        log_info "Docker installed: $(docker --version)"
    fi

    log_info "Docker Compose: $(docker compose version)"

    # ── Add user to docker group ──────────────────────────────────────────────
    local target="${DOCKER_ADD_USER:-${SUDO_USER:-}}"
    if [ -n "$target" ] && ! id -nG "$target" | grep -qw docker; then
        usermod -aG docker "$target"
        log_info "User '$target' added to docker group (re-login required)"
    fi
}
