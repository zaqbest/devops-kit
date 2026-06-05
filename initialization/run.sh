#!/usr/bin/env bash
# Initialization orchestrator — runs all modules in order.
# Sourced/called by init.sh after lib/ is loaded and OS detected.
set -euo pipefail

STATE_FILE="/var/lib/devops-kit/state.env"
MODULES_DIR="${DEVOPS_KIT_ROOT}/initialization/modules"
TOTAL_MODULES=13

_load_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true
}

_save_phase() {
    local key="$1"
    echo "${key}=1" >> "$STATE_FILE"
    log_info "Phase completed: $key"
}

_run_module() {
    local step="$1" script="$2"
    local name
    name=$(basename "$script" .sh)

    log_step "$step" "$TOTAL_MODULES" "Running module: $name"

    # Source module to get PHASE_KEY and main()
    local PHASE_KEY=""
    # shellcheck source=/dev/null
    . "$script"

    # Skip if already completed
    if [ -n "$PHASE_KEY" ] && eval "[ \"\${${PHASE_KEY}:-0}\" = \"1\" ]"; then
        log_info "Module $name already completed, skipping."
        return 0
    fi

    if [ "${DRY_RUN:-0}" = "1" ] && [ -n "$PHASE_KEY" ]; then
        log_dry "Dry-run: would execute module $name"
        main
        return 0
    fi

    main

    # Record completion in state file (skip for modules without a PHASE_KEY)
    if [ -n "$PHASE_KEY" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        _save_phase "$PHASE_KEY"
        # Re-export into current env so subsequent modules see it
        export "${PHASE_KEY}=1"
    fi
}

run_initialization() {
    trap 'error_handler $LINENO $?' ERR
    trap 'cleanup_temp_dirs' EXIT

    _load_state

    # Load config
    local defaults="${DEVOPS_KIT_ROOT}/initialization/config/defaults.env"
    [ -f "$defaults" ] && . "$defaults"

    # User-provided overrides
    if [ -n "${DEVOPS_KIT_CONFIG:-}" ] && [ -f "$DEVOPS_KIT_CONFIG" ]; then
        log_info "Loading user config: $DEVOPS_KIT_CONFIG"
        . "$DEVOPS_KIT_CONFIG"
    fi

    banner "devops-kit VPS Initialization"
    log_info "OS: $OS_PRETTY_NAME | Family: $OS_FAMILY | Init: $INIT_SYSTEM"
    log_info "Log: $LOG_FILE"

    # Run a specific module if --module was requested
    if [ -n "${RUN_MODULE:-}" ]; then
        local script="$MODULES_DIR/${RUN_MODULE}"
        # Allow short name like "06-swap" without .sh
        [ -f "${script}.sh" ] && script="${script}.sh"
        if [ ! -f "$script" ]; then
            die "Module not found: $RUN_MODULE"
        fi
        _run_module 1 "$script"
        return 0
    fi

    local step=0
    for script in "$MODULES_DIR"/[0-9][0-9]-*.sh; do
        (( step++ )) || true

        # If RUN_MODULES is set, skip modules not in the list
        if [ -n "${RUN_MODULES:-}" ]; then
            local num
            num=$(basename "$script" | grep -oE '^[0-9]+')
            local match=0
            for m in $RUN_MODULES; do
                [ "$num" = "$m" ] && { match=1; break; }
            done
            [ "$match" = "0" ] && { log_info "Skipping module $(basename "$script" .sh) (not in RUN_MODULES)"; continue; }
        fi

        _run_module "$step" "$script"
    done

    log_info "Initialization complete."
}
