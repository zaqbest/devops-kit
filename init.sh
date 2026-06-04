#!/usr/bin/env bash
# devops-kit entry point
# Usage: bash init.sh [--auto] [--module NAME] [--dry-run] [--help]
set -euo pipefail

# ── Resolve repository root ────────────────────────────────────────────────────
DEVOPS_KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEVOPS_KIT_ROOT

# ── Bootstrap logging before anything else ────────────────────────────────────
# shellcheck source=lib/log.sh
. "${DEVOPS_KIT_ROOT}/lib/log.sh"

trap 'error_handler $LINENO $?' ERR

# ── Bash version check ────────────────────────────────────────────────────────
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERROR: bash 4+ required (found $BASH_VERSION)" >&2
    echo "Install bash: apt-get install bash  or  yum install bash" >&2
    exit 1
fi

# ── Parse CLI arguments ───────────────────────────────────────────────────────
INTERACTIVE=1
DRY_RUN=0
RUN_MODULE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --auto, -a          Non-interactive mode; use defaults from defaults.env
  --module NAME       Run only the named module (e.g. 06-swap)
  --dry-run           Show what would be done without making changes
  --config FILE       Path to custom config override file
  --help, -h          Show this help

Examples:
  sudo bash init.sh --auto
  sudo bash init.sh --module 06-swap
  sudo bash init.sh --dry-run
  DEVOPS_KIT_CONFIG=/etc/my-server.env bash init.sh --auto
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --auto|-a)
            INTERACTIVE=0
            shift
            ;;
        --module)
            RUN_MODULE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --config)
            DEVOPS_KIT_CONFIG="$2"
            export DEVOPS_KIT_CONFIG
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_warn "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

export INTERACTIVE DRY_RUN RUN_MODULE

# ── Privilege check ───────────────────────────────────────────────────────────
# shellcheck source=lib/privilege.sh
. "${DEVOPS_KIT_ROOT}/lib/privilege.sh"
require_root "$@"

# ── Load remaining libraries ──────────────────────────────────────────────────
# shellcheck source=lib/os.sh
. "${DEVOPS_KIT_ROOT}/lib/os.sh"
# shellcheck source=lib/pkg.sh
. "${DEVOPS_KIT_ROOT}/lib/pkg.sh"
# shellcheck source=lib/net.sh
. "${DEVOPS_KIT_ROOT}/lib/net.sh"
# shellcheck source=lib/util.sh
. "${DEVOPS_KIT_ROOT}/lib/util.sh"

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os

if [ "$OS_FAMILY" = "unknown" ]; then
    die "Unsupported operating system: $OS_PRETTY_NAME (ID=$OS_ID). Supported: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, Alpine."
fi

log_info "Detected OS: $OS_PRETTY_NAME (family=$OS_FAMILY, pkgmgr=$PKG_MGR, arch=$ARCH)"

if [ "${DRY_RUN}" = "1" ]; then
    log_dry "Dry-run mode enabled — no changes will be made."
fi

# ── Hand off to orchestrator ──────────────────────────────────────────────────
# shellcheck source=initialization/run.sh
. "${DEVOPS_KIT_ROOT}/initialization/run.sh"
run_initialization
