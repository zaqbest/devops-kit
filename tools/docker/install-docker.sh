#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-docker.sh
#
# 一键安装 Docker Engine + Compose plugin。
# 支持：Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux / Fedora
#
# 用法：
#   sudo bash scripts/install-docker.sh              # 交互式，安装完询问是否将当前用户加入 docker 组
#   sudo bash scripts/install-docker.sh --yes        # 全部默认 yes（脚本化）
#   sudo bash scripts/install-docker.sh --mirror cn  # 使用国内镜像源（阿里云）
#
# 参考：https://docs.docker.com/engine/install/
# ---------------------------------------------------------------------------
set -euo pipefail

ASSUME_YES=0
MIRROR=""   # "cn" 或空

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1; shift ;;
    --mirror)     MIRROR="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *)
      echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[install-docker]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 sudo 或 root 运行"
    exit 1
  fi
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    err "无法读取 /etc/os-release，不支持的操作系统"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_VERSION_ID="${VERSION_ID:-}"

  # 归一化到 apt / yum 两条路径
  case "$OS_ID" in
    debian|ubuntu|raspbian) PKG_FAMILY=deb ;;
    centos|rhel|rocky|almalinux|fedora|ol) PKG_FAMILY=rpm ;;
    *)
      # 尝试 ID_LIKE
      case "$OS_LIKE" in
        *debian*)         PKG_FAMILY=deb; OS_ID=debian ;;
        *rhel*|*fedora*)  PKG_FAMILY=rpm; OS_ID=centos ;;
        *)
          err "不支持的发行版: ID=$OS_ID ID_LIKE=$OS_LIKE"
          exit 1
        ;;
      esac
    ;;
  esac
  log "检测到系统: $OS_ID $OS_VERSION_ID ($PKG_FAMILY 系)"
}

install_deb() {
  local repo_url="https://download.docker.com"
  local gpg_url="https://download.docker.com/linux/${OS_ID}/gpg"
  if [[ "$MIRROR" == "cn" ]]; then
    repo_url="https://mirrors.aliyun.com/docker-ce"
    gpg_url="https://mirrors.aliyun.com/docker-ce/linux/${OS_ID}/gpg"
    log "使用阿里云镜像"
  fi

  log "卸载旧版本（如果存在）"
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  log "安装依赖"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  log "添加 Docker GPG"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$gpg_url" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  log "添加 apt 源"
  local codename="${OS_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${repo_url}/linux/${OS_ID} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  log "安装 Docker Engine + Compose plugin"
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rpm() {
  local repo_base="https://download.docker.com/linux/centos/docker-ce.repo"
  if [[ "$OS_ID" == "fedora" ]]; then
    repo_base="https://download.docker.com/linux/fedora/docker-ce.repo"
  fi
  if [[ "$MIRROR" == "cn" ]]; then
    repo_base="https://mirrors.aliyun.com/docker-ce/linux/${OS_ID}/docker-ce.repo"
    log "使用阿里云镜像"
  fi

  local pm=yum
  command -v dnf >/dev/null 2>&1 && pm=dnf

  log "卸载旧版本（如果存在）"
  $pm remove -y docker docker-client docker-client-latest docker-common \
                docker-latest docker-latest-logrotate docker-logrotate \
                docker-engine podman-docker 2>/dev/null || true

  log "安装依赖"
  $pm install -y yum-utils device-mapper-persistent-data lvm2 || true

  log "添加 Docker 仓库"
  $pm config-manager --add-repo "$repo_base"

  log "安装 Docker Engine + Compose plugin"
  $pm install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

enable_service() {
  log "启用并启动 docker 服务"
  systemctl enable docker
  systemctl start docker
}

verify() {
  log "验证安装"
  docker --version
  docker compose version
  log "跑一下 hello-world 测试镜像"
  if docker run --rm hello-world >/dev/null 2>&1; then
    log "✓ Docker 正常工作"
  else
    warn "hello-world 未通过（可能是网络问题或镜像未拉到），但 Engine 已安装"
  fi
}

post_install() {
  # 找出真正调用 sudo 的用户
  local target_user="${SUDO_USER:-}"
  if [[ -z "$target_user" || "$target_user" == "root" ]]; then
    return 0
  fi

  if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
    log "用户 $target_user 已在 docker 组"
    return 0
  fi

  local answer="n"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    answer="y"
  else
    read -r -p "是否将用户 $target_user 加入 docker 组（免 sudo 运行 docker）？[y/N] " answer || true
  fi
  if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
    usermod -aG docker "$target_user"
    log "已加入。请注销后重新登录，或运行 'newgrp docker' 生效。"
  fi
}

main() {
  require_root
  detect_os
  case "$PKG_FAMILY" in
    deb) install_deb ;;
    rpm) install_rpm ;;
  esac
  enable_service
  verify
  post_install
  log "全部完成 🎉"
}

main "$@"
