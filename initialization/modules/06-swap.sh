#!/usr/bin/env bash
# Module 06: Configure swap space based on available RAM
PHASE_KEY="SWAP_CONFIGURED"

_calculate_swap_mb() {
    local ram_kb ram_mb ram_gb swap_gb swap_mb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_mb=$(( ram_kb / 1024 ))
    ram_gb=$(( (ram_mb + 1023) / 1024 ))    # ceiling division

    if   [ "$ram_gb" -le 2 ]; then swap_gb=$(( ram_gb * 2 ))
    elif [ "$ram_gb" -le 8 ]; then swap_gb=$ram_gb
    else                            swap_gb=$(( ram_gb / 2 ))
    fi

    local max_gb="${SWAP_MAX_GB:-8}"
    [ "$swap_gb" -gt "$max_gb" ] && swap_gb=$max_gb

    swap_mb=$(( swap_gb * 1024 ))
    [ "$swap_mb" -lt 512 ] && swap_mb=512

    echo "$swap_mb"
}

main() {
    if [ "${SWAP_ENABLED:-1}" = "0" ]; then
        log_info "Swap disabled by configuration, skipping."
        return 0
    fi

    if [ "${SWAP_CONFIGURED:-0}" = "1" ]; then
        log_info "Swap already configured, skipping."
        return 0
    fi

    # Containers: swap creation often fails or is meaningless
    if is_container; then
        log_warn "Container environment detected — skipping swap creation."
        return 0
    fi

    local swap_mb
    swap_mb=$(_calculate_swap_mb)
    log_info "RAM detected. Target swap size: ${swap_mb} MB"

    # Idempotency: check if swapfile already exists and is active with correct size
    if [ -f /swapfile ] && swapon --show --noheadings 2>/dev/null | grep -q /swapfile; then
        local current_mb
        current_mb=$(swapon --show --noheadings --bytes | awk '/\/swapfile/ {printf "%d", $3/1024/1024}')
        if [ "$current_mb" -ge $(( swap_mb - 64 )) ]; then
            log_info "Swapfile already active (${current_mb} MB ≈ ${swap_mb} MB), skipping."
            return 0
        fi
        log_info "Existing swapfile is wrong size, recreating..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi

    # Check available disk space
    local avail_mb
    avail_mb=$(df -BM / | awk 'NR==2 {gsub("M","",$4); print $4}')
    if [ "$avail_mb" -lt $(( swap_mb + 500 )) ]; then
        log_warn "Low disk space (${avail_mb} MB available). Proceeding with swap creation anyway."
    fi

    # Create swapfile
    log_info "Creating /swapfile (${swap_mb} MB)..."

    local fs_type
    fs_type=$(df -T / | awk 'NR==2 {print $2}')

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dry "Would create /swapfile of ${swap_mb} MB on $fs_type filesystem"
        return 0
    fi

    if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        log_warn "fallocate failed, falling back to dd..."
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
    fi

    # btrfs requires CoW disabled on swapfiles
    if [ "$fs_type" = "btrfs" ]; then
        chattr +C /swapfile 2>/dev/null || true
    fi

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Persist in /etc/fstab
    backup_file /etc/fstab
    file_add_line_if_missing /etc/fstab '/swapfile none swap sw 0 0'

    log_info "Swap configured: $(free -h | awk '/Swap:/ {print $2}')"
    log_info "  /swapfile — $(swapon --show --noheadings | grep /swapfile)"
}
