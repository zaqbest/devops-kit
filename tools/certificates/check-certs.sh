#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-certs.sh
#
# 检查 certs/<profile>/ 下 TLS 证书的有效期。会遍历 certs/ 下所有子目录，
# 每个子目录代表一个证书套件（如 letsencrypt / selfsigned）。
#
# 退出码：
#   0  —— 所有 profile 剩余天数 > WARN_DAYS（默认 30）
#   1  —— 至少一个 profile 剩余 <= WARN_DAYS 但 > 0
#   2  —— 至少一个 profile 已过期或读不到证书文件
#
# 用法：
#   ./scripts/check-certs.sh                       # 检查所有 profile，阈值 30 天
#   ./scripts/check-certs.sh letsencrypt           # 只检查指定 profile
#   WARN_DAYS=45 ./scripts/check-certs.sh          # 自定义阈值
#   ./scripts/check-certs.sh --quiet               # 只输出关键信息（适合 crontab）
#
# 建议：可以加进 shell rc，登录 shell 时提醒一下：
#   [[ -o interactive ]] && ~/PanDevelop/tools/docker-kit/scripts/check-certs.sh --quiet
# ---------------------------------------------------------------------------

set -euo pipefail

# --- 参数 ------------------------------------------------------------------
WARN_DAYS="${WARN_DAYS:-30}"
QUIET=false
PROFILES=()
for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET=true ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "未知参数：$arg" >&2; exit 2 ;;
        *)
            PROFILES+=("$arg") ;;
    esac
done

# --- 定位 certs 目录（脚本可从任意路径调用）--------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERTS_ROOT="$REPO_ROOT/certs"

# 未指定 profile 时，扫描 certs/ 下所有含 server.crt 的子目录
if (( ${#PROFILES[@]} == 0 )); then
    while IFS= read -r -d '' d; do
        PROFILES+=("$(basename "$d")")
    done < <(find "$CERTS_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

# --- 颜色（仅 stdout 是 tty 时启用）----------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_YELLOW=""; C_GREEN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

log() { $QUIET || echo "$@"; }

if ! command -v openssl >/dev/null 2>&1; then
    echo "${C_RED}✗ 未找到 openssl，请先安装${C_RESET}" >&2
    exit 2
fi

# --- 单 profile 检查 -------------------------------------------------------
# 返回码：0 健康 / 1 需续期 / 2 过期或缺文件
check_one_profile() {
    local profile="$1"
    local cert_file="$CERTS_ROOT/$profile/server.crt"
    local key_file="$CERTS_ROOT/$profile/server.key"

    log ""
    log "${C_BOLD}▎profile: $profile${C_RESET}"

    if [[ ! -s "$cert_file" ]]; then
        echo "  ${C_RED}✗ 证书文件缺失或为空：$cert_file${C_RESET}" >&2
        return 2
    fi
    if [[ ! -s "$key_file" ]]; then
        echo "  ${C_YELLOW}⚠ 私钥文件缺失或为空：$key_file${C_RESET}" >&2
    fi

    # subject / issuer / SAN 都用一次 openssl 拿全
    local cert_info subject issuer not_before not_after san
    cert_info=$(openssl x509 -in "$cert_file" -noout \
        -subject -issuer -startdate -enddate -ext subjectAltName 2>/dev/null) || {
        echo "  ${C_RED}✗ 证书解析失败：$cert_file${C_RESET}" >&2
        return 2
    }
    subject=$(sed -n 's/^subject=//p'         <<<"$cert_info")
    issuer=$(sed  -n 's/^issuer=//p'          <<<"$cert_info")
    not_before=$(sed -n 's/^notBefore=//p'    <<<"$cert_info")
    not_after=$(sed  -n 's/^notAfter=//p'     <<<"$cert_info")
    san=$(sed -n '/Subject Alternative Name/{n;s/^ *//;p;}' <<<"$cert_info")

    # 私钥与证书是否匹配（比较公钥 SHA256）
    local key_match="?"
    if [[ -s "$key_file" ]]; then
        local crt_hash key_hash
        crt_hash=$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null | openssl sha256 | awk '{print $NF}')
        key_hash=$(openssl pkey  -in "$key_file"  -pubout          2>/dev/null | openssl sha256 | awk '{print $NF}')
        if [[ "$crt_hash" == "$key_hash" ]]; then
            key_match="match"
        else
            key_match="MISMATCH"
        fi
    fi

    # macOS 的 date 不认 GNU 的 -d，做双分支兼容
    local not_after_ts now_ts days_left
    if date --version >/dev/null 2>&1; then
        not_after_ts=$(date -d "$not_after" +%s)
    else
        not_after_ts=$(TZ=UTC date -jf "%b %e %H:%M:%S %Y %Z" "$not_after" +%s)
    fi
    now_ts=$(date +%s)
    days_left=$(( (not_after_ts - now_ts) / 86400 ))

    log "  ${C_DIM}Subject :${C_RESET} $subject"
    log "  ${C_DIM}Issuer  :${C_RESET} $issuer"
    log "  ${C_DIM}SAN     :${C_RESET} $san"
    log "  ${C_DIM}Valid   :${C_RESET} $not_before  →  $not_after"
    if [[ "$key_match" == "match" ]]; then
        log "  ${C_DIM}Key     :${C_RESET} ${C_GREEN}✓ 与证书匹配${C_RESET}"
    elif [[ "$key_match" == "MISMATCH" ]]; then
        log "  ${C_DIM}Key     :${C_RESET} ${C_RED}✗ 与证书不匹配！${C_RESET}"
    fi

    if (( days_left < 0 )); then
        echo "  ${C_RED}${C_BOLD}✗ 已过期 $(( -days_left )) 天！${C_RESET}"
        return 2
    elif (( days_left <= WARN_DAYS )); then
        echo "  ${C_YELLOW}${C_BOLD}⚠ 剩余 $days_left 天，建议续期（阈值 $WARN_DAYS 天）。${C_RESET}"
        return 1
    else
        log "  ${C_GREEN}${C_BOLD}✓ 剩余 $days_left 天，健康。${C_RESET}"
        $QUIET && echo "certs[$profile] OK ($days_left days left)"
        return 0
    fi
}

# --- 遍历所有 profile ------------------------------------------------------
if (( ${#PROFILES[@]} == 0 )); then
    echo "${C_RED}✗ 未在 $CERTS_ROOT 下发现任何 profile 子目录${C_RESET}" >&2
    exit 2
fi

worst=0
for p in "${PROFILES[@]}"; do
    rc=0
    check_one_profile "$p" || rc=$?
    if (( rc > worst )); then worst=$rc; fi
done

# --- Let's Encrypt 续期提示（只在有过期/即将过期时打印一次）----------------
if (( worst == 1 )) && ! $QUIET; then
    cat <<'EOF'

------------------------------------------------------------------------------
Let's Encrypt 续期步骤（Cloudflare DNS-01，需要一个 CF API Token）
------------------------------------------------------------------------------
一次性安装：
    curl -sSfL https://get.acme.sh | sh -s email=acme@zaqbest.com

设置 Cloudflare 凭据（放到 ~/.zshrc 或 ~/.bashrc 里更省事）：
    export CF_Token='你的_Cloudflare_API_Token'         # Zone.Zone:Read + Zone.DNS:Edit
    export CF_Account_ID='你的_Cloudflare_Account_ID'   # Dashboard 右侧栏

签发 / 续签：
    ~/.acme.sh/acme.sh --issue \
      --dns dns_cf \
      -d zaqbest.com -d '*.zaqbest.com' \
      --keylength 2048 \
      --server letsencrypt

安装到本仓库 certs/letsencrypt/（把命令里的路径改成你本地绝对路径）：
    ~/.acme.sh/acme.sh --install-cert -d zaqbest.com \
      --key-file       "$(pwd)/certs/letsencrypt/server.key" \
      --fullchain-file "$(pwd)/certs/letsencrypt/server.crt" \
      --reloadcmd      "docker compose -f docker-compose-nginx.yml restart nginx"

装完再跑一次本脚本确认。
------------------------------------------------------------------------------
EOF
fi

exit "$worst"
