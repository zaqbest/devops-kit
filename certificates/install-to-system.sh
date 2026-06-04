#!/usr/bin/env bash

###############################################################
# System Certificate Installation Script
# Author: Certificate Management Tool
# Description: Install certificates to system trust store
###############################################################

set -e

# 默认值
VERBOSE=false

# 日志函数
log_info() {
    echo "[INFO] $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[VERBOSE] $1"
    fi
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warn() {
    echo "[WARN] $1"
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  --ca-cert=FILE          CA证书文件路径
  --server-cert=FILE      服务器证书文件路径
  --alias=NAME            证书别名 (默认: 自动生成)
  --backup-dir=DIR        备份目录 (默认: /tmp/cert_backup_\$(date))
  -v, --verbose          详细输出模式
  -n, --dry-run          模拟运行（不执行实际操作）
  -h, --help             显示此帮助信息

示例:
  $0 --ca-cert=ca/certs/ca.crt                    # 安装CA证书
  $0 --server-cert=domain/certs/server.crt        # 安装服务器证书
  $0 --ca-cert=ca.crt --alias="MyCA"              # 指定别名
  $0 --ca-cert=ca.crt --verbose                   # 详细输出
  $0 --ca-cert=ca.crt --dry-run                   # 模拟运行

支持的系统:
  - macOS: 使用security命令安装到系统钥匙串
  - Ubuntu/Debian: 使用update-ca-certificates
  - CentOS/RHEL/Fedora: 使用update-ca-trust
  - Arch Linux: 使用trust extract-compat

注意:
  - 此脚本需要以root权限运行 (macOS需要sudo)
  - 会自动检测系统类型并使用对应的证书存储机制
  - macOS会将证书安装到系统钥匙串，可在"钥匙串访问"中查看
EOF
    exit 0
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行，请使用sudo"
        exit 1
    fi
}

# 系统证书存储路径检测
detect_cert_paths() {
    log_info "检测系统证书存储路径..."

    # 检测macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        SYSTEM_TYPE="macos"
        CA_CERT_DIR="/tmp/ca_certs_install"  # 临时目录，实际通过security命令安装
        UPDATE_COMMAND="security_add_trusted_cert"
        log_verbose "检测到macOS系统"
    elif [[ -d "/etc/ssl/certs" && -d "/usr/local/share/ca-certificates" ]]; then
        # Ubuntu/Debian
        SYSTEM_TYPE="debian"
        CA_CERT_DIR="/usr/local/share/ca-certificates"
        UPDATE_COMMAND="update-ca-certificates"
        log_verbose "检测到Debian/Ubuntu系统"
    elif [[ -d "/etc/pki/ca-trust/source/anchors" ]]; then
        # CentOS/RHEL/Fedora
        SYSTEM_TYPE="rhel"
        CA_CERT_DIR="/etc/pki/ca-trust/source/anchors"
        UPDATE_COMMAND="update-ca-trust"
        log_verbose "检测到RHEL/CentOS/Fedora系统"
    elif [[ -d "/etc/ca-certificates/trust-source/anchors" ]]; then
        # Arch Linux
        SYSTEM_TYPE="arch"
        CA_CERT_DIR="/etc/ca-certificates/trust-source/anchors"
        UPDATE_COMMAND="trust extract-compat"
        log_verbose "检测到Arch Linux系统"
    else
        log_error "不支持的系统类型或无法找到证书存储目录"
        log_error "支持的系统: macOS, Ubuntu/Debian, CentOS/RHEL/Fedora, Arch Linux"
        exit 1
    fi

    log_info "系统类型: $SYSTEM_TYPE"
    log_info "证书目录: $CA_CERT_DIR"
    log_info "更新命令: $UPDATE_COMMAND"
}

# 参数解析
parse_arguments() {
    CA_CERT_FILE=""
    SERVER_CERT_FILE=""
    CERT_ALIAS=""
    BACKUP_DIR="/tmp/cert_backup_$(date +%Y%m%d_%H%M%S)"
    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ca-cert=*)
                CA_CERT_FILE="${1#*=}"
                shift
                ;;
            --server-cert=*)
                SERVER_CERT_FILE="${1#*=}"
                shift
                ;;
            --alias=*)
                CERT_ALIAS="${1#*=}"
                shift
                ;;
            --backup-dir=*)
                BACKUP_DIR="${1#*=}"
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
}

# 验证参数
validate_arguments() {
    if [[ -z "$CA_CERT_FILE" && -z "$SERVER_CERT_FILE" ]]; then
        log_error "必须指定至少一个证书文件 (--ca-cert 或 --server-cert)"
        exit 1
    fi

    if [[ -n "$CA_CERT_FILE" && ! -f "$CA_CERT_FILE" ]]; then
        log_error "CA证书文件不存在: $CA_CERT_FILE"
        exit 1
    fi

    if [[ -n "$SERVER_CERT_FILE" && ! -f "$SERVER_CERT_FILE" ]]; then
        log_error "服务器证书文件不存在: $SERVER_CERT_FILE"
        exit 1
    fi

    log_verbose "参数验证通过"
}

# 验证证书文件
validate_certificate() {
    local cert_file="$1"
    local cert_type="$2"

    log_verbose "验证${cert_type}证书: $cert_file"

    if ! openssl x509 -in "$cert_file" -noout -text >/dev/null 2>&1; then
        log_error "无效的${cert_type}证书文件: $cert_file"
        return 1
    fi

    # 显示证书信息
    local subject=$(openssl x509 -noout -subject -in "$cert_file" | sed 's/subject=//')
    local issuer=$(openssl x509 -noout -issuer -in "$cert_file" | sed 's/issuer=//')
    local not_after=$(openssl x509 -noout -enddate -in "$cert_file" | sed 's/notAfter=//')

    log_verbose "${cert_type}证书信息:"
    log_verbose "  Subject: $subject"
    log_verbose "  Issuer: $issuer"
    log_verbose "  Valid Until: $not_after"

    return 0
}

# 生成证书别名
generate_alias() {
    local cert_file="$1"
    local cert_type="$2"

    if [[ -n "$CERT_ALIAS" ]]; then
        echo "$CERT_ALIAS"
        return
    fi

    # 从证书CN提取别名
    local cn=$(openssl x509 -noout -subject -in "$cert_file" | sed -n 's/.*CN=\([^,]*\).*/\1/p' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

    if [[ -n "$cn" ]]; then
        echo "${cert_type}-${cn}"
    else
        echo "${cert_type}-$(basename "$cert_file" .crt)"
    fi
}

# 创建备份
create_backup() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将创建备份目录: $BACKUP_DIR"
        return
    fi

    log_info "创建备份目录: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    # 备份证书存储目录
    if [[ -d "$CA_CERT_DIR" ]]; then
        cp -r "$CA_CERT_DIR" "$BACKUP_DIR/"
        log_verbose "已备份证书目录到: $BACKUP_DIR/"
    fi
}

# macOS证书安装
install_cert_macos() {
    local cert_file="$1"
    local cert_alias="$2"

    log_info "安装证书到macOS钥匙串..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将使用security命令安装证书到系统钥匙串"
        log_info "[DRY-RUN] 证书文件: $cert_file"
        log_info "[DRY-RUN] 证书别名: $cert_alias"
        return 0
    fi

    # 使用security命令添加证书到系统钥匙串
    if security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"; then
        log_success "证书已添加到系统钥匙串: $cert_file"
        log_info "证书别名: $cert_alias"

        # 验证证书是否已安装
        local cert_subject=$(openssl x509 -noout -subject -in "$cert_file" | sed 's/subject=//')
        log_verbose "已安装证书: $cert_subject"

        # 提示用户验证
        log_info "验证安装: 打开 钥匙串访问.app > 系统 > 证书"
    else
        log_error "证书安装失败"
        return 1
    fi
}

# 安装CA证书到系统
install_ca_cert() {
    local cert_file="$1"
    local cert_alias="$2"

    log_info "安装CA证书到系统信任存储..."

    # 验证证书
    if ! validate_certificate "$cert_file" "CA"; then
        return 1
    fi

    # macOS使用特殊处理
    if [[ "$SYSTEM_TYPE" == "macos" ]]; then
        install_cert_macos "$cert_file" "$cert_alias"
        return $?
    fi

    # 生成目标文件名
    local target_file="$CA_CERT_DIR/${cert_alias}.crt"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将复制证书: $cert_file -> $target_file"
        log_info "[DRY-RUN] 将执行: $UPDATE_COMMAND"
        return 0
    fi

    # 复制证书文件
    cp "$cert_file" "$target_file"
    chmod 644 "$target_file"
    log_verbose "证书已复制到: $target_file"

    # 更新系统证书存储
    log_info "更新系统证书存储..."
    if $UPDATE_COMMAND; then
        log_success "CA证书安装成功: $target_file"
        log_info "证书别名: $cert_alias"
    else
        log_error "系统证书存储更新失败"
        return 1
    fi
}

# 安装服务器证书到系统
install_server_cert() {
    local cert_file="$1"
    local cert_alias="$2"

    log_info "安装服务器证书到系统信任存储..."

    # 验证证书
    if ! validate_certificate "$cert_file" "服务器"; then
        return 1
    fi

    # 服务器证书也当作CA证书处理（用于客户端验证）
    install_ca_cert "$cert_file" "$cert_alias"
}

# 显示安装结果
show_installation_result() {
    log_info "证书安装完成！"
    echo
    log_info "安装的证书:"

    if [[ -n "$CA_CERT_FILE" ]]; then
        local ca_alias=$(generate_alias "$CA_CERT_FILE" "ca")
        if [[ "$SYSTEM_TYPE" == "macos" ]]; then
            log_info "  CA证书: 已安装到系统钥匙串 ($CA_CERT_FILE)"
        else
            log_info "  CA证书: $CA_CERT_DIR/${ca_alias}.crt"
        fi
    fi

    if [[ -n "$SERVER_CERT_FILE" ]]; then
        local server_alias=$(generate_alias "$SERVER_CERT_FILE" "server")
        if [[ "$SYSTEM_TYPE" == "macos" ]]; then
            log_info "  服务器证书: 已安装到系统钥匙串 ($SERVER_CERT_FILE)"
        else
            log_info "  服务器证书: $CA_CERT_DIR/${server_alias}.crt"
        fi
    fi

    echo
    log_info "验证安装:"

    case "$SYSTEM_TYPE" in
        "macos")
            log_info "  打开应用程序 > 实用工具 > 钥匙串访问"
            log_info "  选择左侧 '系统' 钥匙串，然后点击 '证书' 分类"
            log_info "  查找已安装的证书（应显示为受信任）"
            log_info "  命令行验证: security find-certificate -a -p /Library/Keychains/System.keychain | openssl x509 -noout -subject"
            ;;
        "debian")
            log_info "  查看系统证书: ls -la $CA_CERT_DIR/"
            log_info "  验证证书: openssl x509 -in $CA_CERT_DIR/证书名.crt -text -noout"
            log_info "  测试SSL连接: openssl s_client -connect 域名:443 -CApath /etc/ssl/certs/"
            ;;
        "rhel")
            log_info "  查看系统证书: ls -la $CA_CERT_DIR/"
            log_info "  验证证书: trust list | grep 证书名"
            log_info "  测试SSL连接: openssl s_client -connect 域名:443 -CAfile /etc/pki/tls/certs/ca-bundle.crt"
            ;;
        "arch")
            log_info "  查看系统证书: ls -la $CA_CERT_DIR/"
            log_info "  验证证书: trust list | grep 证书名"
            log_info "  测试SSL连接: openssl s_client -connect 域名:443 -CApath /etc/ssl/certs/"
            ;;
    esac

    if [[ "$SYSTEM_TYPE" != "macos" ]]; then
        echo
        log_info "备份位置: $BACKUP_DIR"
    fi
}

# 主函数
main() {
    log_info "系统证书安装工具"
    echo

    # 解析参数
    parse_arguments "$@"

    # 检查权限
    if [[ "$DRY_RUN" != "true" ]]; then
        check_root
    fi

    # 验证参数
    validate_arguments

    # 检测系统
    detect_cert_paths

    # 创建备份
    create_backup

    echo
    log_info "开始安装证书..."

    # 安装CA证书
    if [[ -n "$CA_CERT_FILE" ]]; then
        local ca_alias=$(generate_alias "$CA_CERT_FILE" "ca")
        install_ca_cert "$CA_CERT_FILE" "$ca_alias"
    fi

    # 安装服务器证书
    if [[ -n "$SERVER_CERT_FILE" ]]; then
        local server_alias=$(generate_alias "$SERVER_CERT_FILE" "server")
        install_server_cert "$SERVER_CERT_FILE" "$server_alias"
    fi

    echo
    if [[ "$DRY_RUN" != "true" ]]; then
        show_installation_result
    else
        log_info "[DRY-RUN] 模拟运行完成，未执行实际操作"
    fi
}

# 运行主函数
main "$@"
