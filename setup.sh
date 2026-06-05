#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[error] GITHUB_TOKEN environment variable is not set." >&2
    echo "        export GITHUB_TOKEN=<your_token> and re-run." >&2
    exit 1
fi

REPO_URL="https://${GITHUB_TOKEN}@github.com/zaqbest/devops-kit.git"
CLONE_DIR="/opt/devops-kit"
BASHRC="${HOME}/.bashrc"

# ── 1. Install git ────────────────────────────────────────────────────────────
install_git() {
    if command -v git &>/dev/null; then
        echo "[info] git already installed: $(git --version)"
        return
    fi

    echo "[info] installing git..."

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop)
                apt-get update -qq && apt-get install -y git ;;
            centos|rhel|almalinux|rocky)
                yum install -y git ;;
            fedora)
                dnf install -y git ;;
            opensuse*|sles)
                zypper install -y git ;;
            arch|manjaro)
                pacman -Sy --noconfirm git ;;
            alpine)
                apk add --no-cache git ;;
            *)
                echo "[error] unsupported Linux distro: ${ID}" >&2; exit 1 ;;
        esac
    elif [[ "$(uname)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install git
        else
            xcode-select --install 2>/dev/null || true
            echo "[info] installed git via Xcode Command Line Tools"
        fi
    else
        echo "[error] unsupported OS: $(uname)" >&2; exit 1
    fi

    echo "[info] git installed: $(git --version)"
}

# ── 2. Persist GITHUB_TOKEN to ~/.bashrc ─────────────────────────────────────
set_github_token() {
    local marker="export GITHUB_TOKEN="
    if grep -qF "${marker}" "${BASHRC}" 2>/dev/null; then
        echo "[info] GITHUB_TOKEN already set in ${BASHRC}, updating..."
        sed -i.bak "/${marker}/d" "${BASHRC}"
    fi
    echo "export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"" >> "${BASHRC}"
    echo "[info] GITHUB_TOKEN written to ${BASHRC}"
    export GITHUB_TOKEN
}

# ── 3. Clone repository ───────────────────────────────────────────────────────
clone_repo() {
    if [[ -d "${CLONE_DIR}/.git" ]]; then
        echo "[info] repo already cloned at ${CLONE_DIR}, pulling latest..."
        git -C "${CLONE_DIR}" pull --ff-only
        return
    fi

    echo "[info] cloning into ${CLONE_DIR}..."
    git clone "${REPO_URL}" "${CLONE_DIR}"
    echo "[info] clone complete"
}

# ── 4. Run init script ────────────────────────────────────────────────────────
run_init() {
    local init_script="${CLONE_DIR}/init.sh"
    if [[ ! -f "${init_script}" ]]; then
        echo "[error] init script not found: ${init_script}" >&2; exit 1
    fi
    chmod +x "${init_script}"
    echo "[info] running ${init_script}..."
    bash "${init_script}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
install_git
set_github_token
clone_repo
run_init
