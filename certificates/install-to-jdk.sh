#!/usr/bin/env bash

###############################################################
# JDK Certificate Installation Script
# Author: Certificate Management Tool
# Description: Install certificates to JDK keystore (supports SDKMAN)
###############################################################

set -e

# 默认值
DEFAULT_KEYSTORE_PASSWORD="changeit"
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
  --cert=FILE                证书文件路径
  --alias=NAME               证书别名
  --java-home=PATH           指定JDK路径
  --keystore-password=PWD    keystore密码 (默认: changeit)
  --backup-dir=DIR           备份目录 (默认: /tmp/jdk_backup_\$(date))

  --list-jdk                 列出所有检测到的JDK
  --list-certs               列出keystore中的证书
  --delete-alias=NAME        删除指定别名的证书

  --sdkman-current          使用SDKMAN当前激活的JDK
  --sdkman-version=VERSION  使用指定的SDKMAN JDK版本
  --all-jdk                 安装到所有检测到的JDK
  --all-sdkman              安装到所有SDKMAN管理的JDK
  --prefer-sdkman           优先使用SDKMAN管理的JDK

  -v, --verbose             详细输出模式
  -n, --dry-run             模拟运行（不执行实际操作）
  -h, --help                显示此帮助信息

示例:
  $0 --list-jdk                              # 列出所有JDK
  $0 --cert=ca.crt --alias="MyCA"            # 安装到默认JDK
  $0 --cert=ca.crt --alias="MyCA" --all-jdk  # 安装到所有JDK
  $0 --cert=ca.crt --alias="MyCA" --sdkman-current  # 安装到SDKMAN当前版本
  $0 --cert=ca.crt --alias="MyCA" --sdkman-version="17.0.8-tem"  # 指定版本
  $0 --list-certs --java-home=/usr/lib/jvm/java-11  # 查看指定JDK的证书
  $0 --delete-alias="OldCA" --java-home=/usr/lib/jvm/java-11     # 删除证书

注意:
  - 某些操作可能需要root权限
  - 会自动备份原始keystore文件
  - 支持多种JDK安装方式：系统安装、SDKMAN、手动安装等
EOF
    exit 0
}

# 检测SDKMAN安装的JDK
detect_sdkman_jdk() {
    local sdkman_java_dir="$HOME/.sdkman/candidates/java"
    local jdk_installations=()
    
    if [[ ! -d "$sdkman_java_dir" ]]; then
        log_verbose "未找到SDKMAN Java安装目录"
        return 0
    fi
    
    log_verbose "检测SDKMAN管理的JDK..."
    
    # 检查当前激活的JDK版本
    if [[ -L "$sdkman_java_dir/current" ]]; then
        local current_jdk=$(readlink "$sdkman_java_dir/current")
        if [[ -f "$current_jdk/bin/keytool" ]]; then
            jdk_installations+=("$current_jdk|sdkman-current|$(parse_sdkman_version "$current_jdk")")
            log_verbose "找到SDKMAN当前JDK: $current_jdk"
        fi
    fi
    
    # 检查所有安装的版本
    for version_dir in "$sdkman_java_dir"/*; do
        if [[ -d "$version_dir" && "$version_dir" != "$sdkman_java_dir/current" ]]; then
            if [[ -f "$version_dir/bin/keytool" ]]; then
                local version_name=$(basename "$version_dir")
                local version_desc=$(parse_sdkman_version "$version_dir")
                jdk_installations+=("$version_dir|sdkman-$version_name|$version_desc")
                log_verbose "找到SDKMAN JDK版本: $version_name -> $version_dir"
            fi
        fi
    done
    
    printf '%s\n' "${jdk_installations[@]}"
}

# 解析SDKMAN版本信息
parse_sdkman_version() {
    local version_dir="$1"
    local version_name=$(basename "$version_dir")
    
    # 解析版本格式：17.0.8-tem -> Java 17 (Temurin)
    if [[ "$version_name" =~ ^([0-9]+)\.?[0-9]*\.?[0-9]*-(.+)$ ]]; then
        local major_version="${BASH_REMATCH[1]}"
        local vendor="${BASH_REMATCH[2]}"
        
        case "$vendor" in
            "tem") vendor="Temurin" ;;
            "amzn") vendor="Amazon Corretto" ;;
            "zulu") vendor="Azul Zulu" ;;
            "oracle") vendor="Oracle" ;;
            "graalvm") vendor="GraalVM" ;;
            "liberica") vendor="BellSoft Liberica" ;;
            *) vendor="$vendor" ;;
        esac
        
        echo "Java $major_version ($vendor)"
    else
        echo "$version_name"
    fi
}

# 获取Java版本信息
get_java_version() {
    local java_home="$1"
    local version_output
    
    if version_output=$("$java_home/bin/java" -version 2>&1 | head -n1); then
        if [[ "$version_output" =~ version\ \"([0-9]+)\.?[0-9]*\.?[0-9]*[^\"]*\" ]]; then
            local version="${BASH_REMATCH[1]}"
            echo "Java $version"
        else
            echo "Unknown"
        fi
    else
        echo "Unknown"
    fi
}

# 检测所有JDK安装
detect_all_jdk_installations() {
    local jdk_paths=()
    
    log_verbose "开始检测系统中的JDK安装..."
    
    # 1. 检测SDKMAN管理的JDK
    while IFS= read -r jdk_info; do
        if [[ -n "$jdk_info" ]]; then
            jdk_paths+=("$jdk_info")
        fi
    done < <(detect_sdkman_jdk)
    
    # 2. 检测系统标准路径的JDK
    local system_search_paths=(
        "/usr/lib/jvm"           # Ubuntu/Debian
        "/usr/java"              # CentOS/RHEL traditional
        "/opt/java"              # Manual installations
        "/opt/jdk"               # Alternative path
        "/Library/Java/JavaVirtualMachines"  # macOS
    )
    
    for search_path in "${system_search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            while IFS= read -r -d '' java_dir; do
                if [[ -f "$java_dir/bin/keytool" && -f "$java_dir/lib/security/cacerts" ]]; then
                    # 检查是否已经被SDKMAN检测到（避免重复）
                    local is_duplicate=false
                    for existing in "${jdk_paths[@]}"; do
                        if [[ "${existing%%|*}" == "$java_dir" ]]; then
                            is_duplicate=true
                            break
                        fi
                    done
                    
                    if [[ "$is_duplicate" == "false" ]]; then
                        local java_version=$(get_java_version "$java_dir")
                        jdk_paths+=("$java_dir|system|$java_version")
                        log_verbose "找到系统JDK: $java_dir ($java_version)"
                    fi
                fi
            done < <(find "$search_path" -maxdepth 2 -type d \( -name "java*" -o -name "jdk*" -o -name "openjdk*" \) -print0 2>/dev/null)
        fi
    done
    
    # 3. 检测环境变量JAVA_HOME
    if [[ -n "$JAVA_HOME" && -f "$JAVA_HOME/bin/keytool" ]]; then
        local is_duplicate=false
        for existing in "${jdk_paths[@]}"; do
            if [[ "${existing%%|*}" == "$JAVA_HOME" ]]; then
                is_duplicate=true
                break
            fi
        done
        
        if [[ "$is_duplicate" == "false" ]]; then
            local java_version=$(get_java_version "$JAVA_HOME")
            jdk_paths+=("$JAVA_HOME|env|$java_version")
            log_verbose "找到环境变量JDK: $JAVA_HOME ($java_version)"
        fi
    fi
    
    # 4. 检测当前PATH中的java
    local java_executable=$(which java 2>/dev/null)
    if [[ -n "$java_executable" ]]; then
        local java_home_from_path=$(dirname "$(dirname "$java_executable")")
        if [[ -f "$java_home_from_path/bin/keytool" ]]; then
            local is_duplicate=false
            for existing in "${jdk_paths[@]}"; do
                if [[ "${existing%%|*}" == "$java_home_from_path" ]]; then
                    is_duplicate=true
                    break
                fi
            done
            
            if [[ "$is_duplicate" == "false" ]]; then
                local java_version=$(get_java_version "$java_home_from_path")
                jdk_paths+=("$java_home_from_path|path|$java_version")
                log_verbose "找到PATH中的JDK: $java_home_from_path ($java_version)"
            fi
        fi
    fi
    
    printf '%s\n' "${jdk_paths[@]}" | sort -u
}

# 参数解析
parse_arguments() {
    CERT_FILE=""
    CERT_ALIAS=""
    JAVA_HOME_PARAM=""
    KEYSTORE_PASSWORD="$DEFAULT_KEYSTORE_PASSWORD"
    BACKUP_DIR="/tmp/jdk_backup_$(date +%Y%m%d_%H%M%S)"
    DRY_RUN=false
    
    # 操作模式
    LIST_JDK=false
    LIST_CERTS=false
    DELETE_ALIAS=""
    
    # SDKMAN选项
    SDKMAN_CURRENT=false
    SDKMAN_VERSION=""
    ALL_JDK=false
    ALL_SDKMAN=false
    PREFER_SDKMAN=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cert=*)
                CERT_FILE="${1#*=}"
                shift
                ;;
            --alias=*)
                CERT_ALIAS="${1#*=}"
                shift
                ;;
            --java-home=*)
                JAVA_HOME_PARAM="${1#*=}"
                shift
                ;;
            --keystore-password=*)
                KEYSTORE_PASSWORD="${1#*=}"
                shift
                ;;
            --backup-dir=*)
                BACKUP_DIR="${1#*=}"
                shift
                ;;
            --list-jdk)
                LIST_JDK=true
                shift
                ;;
            --list-certs)
                LIST_CERTS=true
                shift
                ;;
            --delete-alias=*)
                DELETE_ALIAS="${1#*=}"
                shift
                ;;
            --sdkman-current)
                SDKMAN_CURRENT=true
                shift
                ;;
            --sdkman-version=*)
                SDKMAN_VERSION="${1#*=}"
                shift
                ;;
            --all-jdk)
                ALL_JDK=true
                shift
                ;;
            --all-sdkman)
                ALL_SDKMAN=true
                shift
                ;;
            --prefer-sdkman)
                PREFER_SDKMAN=true
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

# 列出所有检测到的JDK
list_all_jdk() {
    log_info "检测到的JDK安装:"
    echo
    
    local counter=1
    while IFS= read -r jdk_info; do
        if [[ -n "$jdk_info" ]]; then
            IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
            
            local status=""
            if [[ "$source_type" == "sdkman-current" ]]; then
                status=" [Current]"
            fi
            
            case "$source_type" in
                sdkman-*)
                    echo "$counter. $java_home (SDKMAN - $version_desc)$status"
                    ;;
                system)
                    echo "$counter. $java_home (System - $version_desc)"
                    ;;
                env)
                    echo "$counter. $java_home (JAVA_HOME - $version_desc)"
                    ;;
                path)
                    echo "$counter. $java_home (PATH - $version_desc)"
                    ;;
            esac
            
            ((counter++))
        fi
    done < <(detect_all_jdk_installations)
    
    if [[ $counter -eq 1 ]]; then
        log_warn "未检测到任何JDK安装"
        echo
        log_info "请确保已安装JDK，或使用以下方式安装："
        log_info "  SDKMAN: curl -s \"https://get.sdkman.io\" | bash && sdk install java"
        log_info "  系统包管理器: apt install openjdk-11-jdk 或 yum install java-11-openjdk-devel"
    fi
}

# 列出keystore中的证书
list_keystore_certs() {
    local java_home="$1"
    local keystore_path="$java_home/lib/security/cacerts"
    
    if [[ ! -f "$keystore_path" ]]; then
        log_error "Keystore文件不存在: $keystore_path"
        return 1
    fi
    
    log_info "JDK Keystore中的证书: $keystore_path"
    echo
    
    "$java_home/bin/keytool" -list -keystore "$keystore_path" \
        -storepass "$KEYSTORE_PASSWORD" | grep -E "^[a-zA-Z0-9].*," | sort
}

# 验证证书文件
validate_certificate() {
    local cert_file="$1"
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "证书文件不存在: $cert_file"
        return 1
    fi
    
    if ! openssl x509 -in "$cert_file" -noout -text >/dev/null 2>&1; then
        log_error "无效的证书文件: $cert_file"
        return 1
    fi
    
    # 显示证书信息
    local subject=$(openssl x509 -noout -subject -in "$cert_file" | sed 's/subject=//')
    local issuer=$(openssl x509 -noout -issuer -in "$cert_file" | sed 's/issuer=//')
    local not_after=$(openssl x509 -noout -enddate -in "$cert_file" | sed 's/notAfter=//')
    
    log_verbose "证书信息:"
    log_verbose "  Subject: $subject"
    log_verbose "  Issuer: $issuer"
    log_verbose "  Valid Until: $not_after"
    
    return 0
}

# 安装证书到JDK keystore
install_cert_to_keystore() {
    local cert_file="$1"
    local cert_alias="$2"  
    local java_home="$3"
    local keystore_path="$java_home/lib/security/cacerts"
    
    log_info "安装证书到JDK: $java_home"
    log_verbose "  证书文件: $cert_file"
    log_verbose "  证书别名: $cert_alias"
    log_verbose "  Keystore: $keystore_path"
    
    # 验证证书
    if ! validate_certificate "$cert_file"; then
        return 1
    fi
    
    # 检查keystore文件
    if [[ ! -f "$keystore_path" ]]; then
        log_error "Keystore文件不存在: $keystore_path"
        return 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将安装证书到: $keystore_path"
        log_info "[DRY-RUN] 证书别名: $cert_alias"
        return 0
    fi
    
    # 备份原始keystore
    local backup_file="${keystore_path}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$keystore_path" "$backup_file"
    log_verbose "已备份keystore: $backup_file"
    
    # 检查证书是否已存在
    if "$java_home/bin/keytool" -list -keystore "$keystore_path" \
       -storepass "$KEYSTORE_PASSWORD" -alias "$cert_alias" >/dev/null 2>&1; then
        log_warn "证书别名已存在，将删除后重新安装: $cert_alias"
        "$java_home/bin/keytool" -delete -keystore "$keystore_path" \
            -storepass "$KEYSTORE_PASSWORD" -alias "$cert_alias"
    fi
    
    # 导入证书
    if "$java_home/bin/keytool" -importcert -file "$cert_file" \
        -keystore "$keystore_path" -storepass "$KEYSTORE_PASSWORD" \
        -alias "$cert_alias" -noprompt; then
        log_success "证书已成功安装到JDK: $java_home"
        log_info "  别名: $cert_alias"
        log_info "  Keystore: $keystore_path"
        log_info "  备份: $backup_file"
    else
        log_error "证书安装失败"
        # 恢复备份
        cp "$backup_file" "$keystore_path"
        log_info "已恢复原始keystore"
        return 1
    fi
}

# 删除证书
delete_cert_from_keystore() {
    local cert_alias="$1"
    local java_home="$2"
    local keystore_path="$java_home/lib/security/cacerts"
    
    log_info "从JDK删除证书: $java_home"
    log_info "  证书别名: $cert_alias"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] 将删除证书别名: $cert_alias"
        return 0
    fi
    
    # 检查证书是否存在
    if ! "$java_home/bin/keytool" -list -keystore "$keystore_path" \
       -storepass "$KEYSTORE_PASSWORD" -alias "$cert_alias" >/dev/null 2>&1; then
        log_warn "证书别名不存在: $cert_alias"
        return 1
    fi
    
    # 备份原始keystore
    local backup_file="${keystore_path}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$keystore_path" "$backup_file"
    log_verbose "已备份keystore: $backup_file"
    
    # 删除证书
    if "$java_home/bin/keytool" -delete -keystore "$keystore_path" \
        -storepass "$KEYSTORE_PASSWORD" -alias "$cert_alias"; then
        log_success "证书已删除: $cert_alias"
        log_info "  备份: $backup_file"
    else
        log_error "证书删除失败"
        return 1
    fi
}

# 获取目标JDK列表
get_target_jdk_list() {
    local target_jdks=()
    
    if [[ "$LIST_JDK" == "true" ]]; then
        return 0
    fi
    
    # 检测所有JDK
    local all_jdks=()
    while IFS= read -r jdk_info; do
        if [[ -n "$jdk_info" ]]; then
            all_jdks+=("$jdk_info")
        fi
    done < <(detect_all_jdk_installations)
    
    if [[ ${#all_jdks[@]} -eq 0 ]]; then
        log_error "未检测到任何JDK安装"
        exit 1
    fi
    
    # 根据参数选择目标JDK
    if [[ "$ALL_JDK" == "true" ]]; then
        # 所有JDK
        target_jdks=("${all_jdks[@]}")
    elif [[ "$ALL_SDKMAN" == "true" ]]; then
        # 所有SDKMAN JDK
        for jdk_info in "${all_jdks[@]}"; do
            IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
            if [[ "$source_type" =~ ^sdkman- ]]; then
                target_jdks+=("$jdk_info")
            fi
        done
    elif [[ "$SDKMAN_CURRENT" == "true" ]]; then
        # SDKMAN当前JDK
        for jdk_info in "${all_jdks[@]}"; do
            IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
            if [[ "$source_type" == "sdkman-current" ]]; then
                target_jdks+=("$jdk_info")
                break
            fi
        done
    elif [[ -n "$SDKMAN_VERSION" ]]; then
        # 指定SDKMAN版本
        for jdk_info in "${all_jdks[@]}"; do
            IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
            if [[ "$source_type" == "sdkman-$SDKMAN_VERSION" ]]; then
                target_jdks+=("$jdk_info")
                break
            fi
        done
    elif [[ -n "$JAVA_HOME_PARAM" ]]; then
        # 指定JDK路径
        for jdk_info in "${all_jdks[@]}"; do
            IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
            if [[ "$java_home" == "$JAVA_HOME_PARAM" ]]; then
                target_jdks+=("$jdk_info")
                break
            fi
        done
    else
        # 默认JDK（优先SDKMAN current，然后JAVA_HOME，最后第一个）
        local default_jdk=""
        
        if [[ "$PREFER_SDKMAN" == "true" ]]; then
            for jdk_info in "${all_jdks[@]}"; do
                IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
                if [[ "$source_type" == "sdkman-current" ]]; then
                    default_jdk="$jdk_info"
                    break
                fi
            done
        fi
        
        if [[ -z "$default_jdk" ]]; then
            for jdk_info in "${all_jdks[@]}"; do
                IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
                if [[ "$source_type" == "env" ]]; then
                    default_jdk="$jdk_info"
                    break
                fi
            done
        fi
        
        if [[ -z "$default_jdk" ]]; then
            default_jdk="${all_jdks[0]}"
        fi
        
        target_jdks+=("$default_jdk")
    fi
    
    printf '%s\n' "${target_jdks[@]}"
}

# 验证参数
validate_arguments() {
    # 对于列出操作，不需要证书文件
    if [[ "$LIST_JDK" == "true" || "$LIST_CERTS" == "true" ]]; then
        return 0
    fi
    
    # 对于删除操作，需要别名
    if [[ -n "$DELETE_ALIAS" ]]; then
        return 0
    fi
    
    # 对于安装操作，需要证书文件和别名
    if [[ -z "$CERT_FILE" ]]; then
        log_error "必须指定证书文件 (--cert)"
        exit 1
    fi
    
    if [[ -z "$CERT_ALIAS" ]]; then
        log_error "必须指定证书别名 (--alias)"
        exit 1
    fi
    
    if [[ ! -f "$CERT_FILE" ]]; then
        log_error "证书文件不存在: $CERT_FILE"
        exit 1
    fi
    
    log_verbose "参数验证通过"
}

# 主函数
main() {
    log_info "JDK证书安装工具"
    echo
    
    # 解析参数
    parse_arguments "$@"
    
    # 验证参数
    validate_arguments
    
    # 列出JDK
    if [[ "$LIST_JDK" == "true" ]]; then
        list_all_jdk
        return 0
    fi
    
    # 获取目标JDK列表
    local target_jdks=()
    while IFS= read -r jdk_info; do
        if [[ -n "$jdk_info" ]]; then
            target_jdks+=("$jdk_info")
        fi
    done < <(get_target_jdk_list)
    
    if [[ ${#target_jdks[@]} -eq 0 ]]; then
        log_error "未找到匹配的JDK"
        exit 1
    fi
    
    # 处理每个目标JDK
    for jdk_info in "${target_jdks[@]}"; do
        IFS='|' read -r java_home source_type version_desc <<< "$jdk_info"
        
        echo
        log_info "处理JDK: $java_home ($version_desc)"
        
        # 列出证书
        if [[ "$LIST_CERTS" == "true" ]]; then
            list_keystore_certs "$java_home"
            continue
        fi
        
        # 删除证书
        if [[ -n "$DELETE_ALIAS" ]]; then
            delete_cert_from_keystore "$DELETE_ALIAS" "$java_home"
            continue
        fi
        
        # 安装证书
        if [[ -n "$CERT_FILE" && -n "$CERT_ALIAS" ]]; then
            install_cert_to_keystore "$CERT_FILE" "$CERT_ALIAS" "$java_home"
        fi
    done
    
    echo
    if [[ "$DRY_RUN" != "true" ]]; then
        log_success "操作完成！"
        if [[ -n "$CERT_FILE" && -n "$CERT_ALIAS" ]]; then
            log_info "证书 '$CERT_ALIAS' 已安装到 ${#target_jdks[@]} 个JDK"
        fi
    else
        log_info "[DRY-RUN] 模拟运行完成，未执行实际操作"
    fi
}

# 运行主函数
main "$@"
