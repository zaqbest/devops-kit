#!/usr/bin/env bash
# Module 04: Configure system locale
PHASE_KEY="LOCALE_SET"

main() {
    [ "${LOCALE_SET:-0}" = "1" ] && { log_info "Locale already configured, skipping."; return 0; }

    local locale="${LOCALE:-en_US.UTF-8}"
    log_info "Setting locale: $locale"

    case "$OS_FAMILY" in
        debian)
            pkg_install_if_missing locales
            if ! grep -q "^$locale" /etc/locale.gen 2>/dev/null; then
                echo "$locale UTF-8" >> /etc/locale.gen
            fi
            locale-gen
            update-locale LANG="$locale" LC_ALL="$locale"
            ;;
        rhel)
            pkg_install_if_missing glibc-locale-source glibc-langpack-en 2>/dev/null || true
            if command -v localectl &>/dev/null; then
                localectl set-locale LANG="$locale"
            else
                echo "LANG=$locale" > /etc/locale.conf
            fi
            ;;
        alpine)
            pkg_install_if_missing musl-locales musl-locales-lang 2>/dev/null || true
            mkdir -p /etc/profile.d
            cat > /etc/profile.d/locale.sh <<EOF
export LANG="$locale"
export LC_ALL="$locale"
EOF
            ;;
    esac

    log_info "Locale configured: $locale"
}
