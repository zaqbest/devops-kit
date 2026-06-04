#!/usr/bin/env bash
# Network utilities — source this file, do not execute directly.

net_public_ipv4() {
    local ip
    for url in \
        'https://api.ipify.org' \
        'https://ifconfig.me/ip' \
        'https://icanhazip.com' \
        'https://ipecho.net/plain'; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && \
            [ -n "$ip" ] && echo "$ip" && return 0
    done
    # dig fallback
    if command -v dig &>/dev/null; then
        dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null && return 0
    fi
    return 1
}

net_public_ipv6() {
    local ip
    for url in \
        'https://api6.ipify.org' \
        'https://ipv6.icanhazip.com'; do
        ip=$(curl -6 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && \
            [ -n "$ip" ] && echo "$ip" && return 0
    done
    return 1
}

net_primary_interface() {
    ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

net_dns_check() {
    local host="$1"
    if command -v dig &>/dev/null; then
        dig +short "$host" &>/dev/null && return 0
    elif command -v host &>/dev/null; then
        host "$host" &>/dev/null && return 0
    else
        nslookup "$host" &>/dev/null && return 0
    fi
    return 1
}

net_port_open() {
    local host="$1" port="$2"
    if command -v nc &>/dev/null; then
        nc -z -w 3 "$host" "$port" &>/dev/null
    else
        # bash built-in TCP
        (echo >/dev/tcp/"$host"/"$port") &>/dev/null
    fi
}

net_wait_for_port() {
    local port="$1" timeout="${2:-30}"
    local elapsed=0
    while ! net_port_open 127.0.0.1 "$port" && [ "$elapsed" -lt "$timeout" ]; do
        sleep 1
        (( elapsed++ )) || true
    done
    [ "$elapsed" -lt "$timeout" ]
}

net_is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    return 1
}
