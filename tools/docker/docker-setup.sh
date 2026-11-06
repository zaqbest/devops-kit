#!/usr/bin/env bash
# docker-setup.sh - 安装 Docker CE（支持 HTTP/SOCKS 代理，官方源）
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "\033[0;31m[ERROR]${NC} %s\n" "$*" >&2; }

# curl 超时控制，避免卡住
CURL_OPTS=(--connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-max-time 60)

GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
REPO_URL="https://download.docker.com/linux/ubuntu"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "请使用 root 权限运行：sudo -E bash $0"
    exit 1
  fi
}

setup_apt_proxy() {
  if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
    info "配置 apt 代理：${http_proxy:-}${https_proxy:-}"
    cat > /etc/apt/apt.conf.d/99proxy <<EOF
Acquire::http::Proxy "${http_proxy:-}";
Acquire::https::Proxy "${https_proxy:-}";
EOF
  fi
}

detect_os() {
  [[ -f /etc/os-release ]] || { error "缺少 /etc/os-release"; exit 1; }
  . /etc/os-release
  case "$ID" in
    ubuntu|debian) info "检测到系统：$PRETTY_NAME" ;;
    *) error "此脚本仅支持 Ubuntu/Debian，当前：$ID"; exit 1 ;;
  esac
  CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$CODENAME" ]] || { error "无法获取 VERSION_CODENAME"; exit 1; }
  ARCH="$(dpkg --print-architecture)"
}

install_prereqs() {
  info "更新 apt 并安装基础依赖..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
}

setup_gpg() {
  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg
  info "下载 Docker GPG 密钥：$GPG_URL"
  curl "${CURL_OPTS[@]}" -fsSL "$GPG_URL" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  info "GPG 密钥已保存"
}

setup_repo() {
  info "添加 Docker apt 官方源：$REPO_URL"
  echo \
    "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $REPO_URL \
    $CODENAME stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
}

install_docker() {
  info "安装 Docker CE..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

configure_docker_proxy() {
  if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
    info "配置 Docker daemon 拉取镜像代理..."
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${http_proxy:-}"
Environment="HTTPS_PROXY=${https_proxy:-}"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF
    systemctl daemon-reload
  fi
}

start_docker() {
  info "启动并设置开机自启 Docker..."
  systemctl enable --now docker
}

verify() {
  info "验证 Docker 安装..."
  docker --version
  docker run --rm hello-world >/dev/null 2>&1 \
    && info "hello-world 运行正常" \
    || warn "hello-world 未运行（可能是代理或镜像网络问题，不影响 Docker 本身）"
}

cleanup_proxy() {
  if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
    info "清理安装过程中的代理配置..."
    rm -f /etc/apt/apt.conf.d/99proxy
    rm -f /etc/systemd/system/docker.service.d/proxy.conf
    systemctl daemon-reload
    info "代理配置已移除"
  fi
}

main() {
  require_root
  setup_apt_proxy
  detect_os
  install_prereqs
  setup_gpg
  setup_repo
  install_docker
  configure_docker_proxy
  start_docker
  verify
  cleanup_proxy

  echo "================================================"
  info "Docker 安装完成！"
  info "将当前用户加入 docker 组（免 sudo 运行 docker）："
  info "  sudo usermod -aG docker $USER"
  info "  然后重新登录或执行：newgrp docker"
  echo "================================================"
}

main "$@"