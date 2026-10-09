#!/usr/bin/env bash

###############################################################
# 域名证书
###############################################################

# 使用说明函数
usage() {
    echo "Usage: $0 <domain_name> [--no-ca]"
    echo ""
    echo "Arguments:"
    echo "  domain_name         Domain name (required)"
    echo ""
    echo "Options:"
    echo "  --no-ca            Generate self-signed certificate (without CA)"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 example.com              # Use CA signing (default)"
    echo "  $0 example.com --no-ca      # Generate self-signed certificate"
    echo ""
    echo "Description:"
    echo "  - Default mode uses CA certificate to sign domain certificate"
    echo "  - Use --no-ca option to generate independent self-signed certificate"
    echo "  - CA mode requires running generate_ca.sh first"
    exit 1
}

# 初始化变量
USE_CA=1
DOMAIN_NAME=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-ca)
            USE_CA=0
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$DOMAIN_NAME" ]; then
                DOMAIN_NAME=$1
            else
                echo "Error: Unknown argument '$1'"
                usage
            fi
            shift
            ;;
    esac
done

# 检查参数
if [ -z "$DOMAIN_NAME" ]; then
    echo "Error: Domain name is required"
    usage
fi

export DEFAULT_KEY_PASS=123456
export CA_KEY_PASS=${DEFAULT_KEY_PASS}
export export PK12_KEY_PASS=${DEFAULT_KEY_PASS}

export EXPIRE_DAYS=365
export OPENSSL_CONFIG_TEMPLATE=openssl.cnf.template
export OPENSSL_CONFIG_FILE=/tmp/custom_openssl_${1}.cnf

export CA_ROOT_NAME=ca
export CA_CA_NAME=ca
export CA_PRIVATE_FILE=${CA_ROOT_NAME}/private/${CA_CA_NAME}.key
export CA_CERT_FILE=${CA_ROOT_NAME}/certs/${CA_CA_NAME}.crt
export CA_SRL_FILE=${CA_ROOT_NAME}/certs/${CA_CA_NAME}.srl

# DOMAIN_NAME 已在参数解析时设置
export DOMAIN_ROOT_PATH=domain/${DOMAIN_NAME}
export DOMAIN_PRIVATE_PATH=${DOMAIN_ROOT_PATH}/private
export DOMAIN_CERT_PATH=${DOMAIN_ROOT_PATH}/certs
export DOMAIN_PRIVATE_FILE=${DOMAIN_PRIVATE_PATH}/${DOMAIN_NAME}.key
export DOMAIN_PRIVATE_DECRYPTED_FILE=${DOMAIN_PRIVATE_PATH}/${DOMAIN_NAME}_decrypted.key
export DOMAIN_CERT_FILE=${DOMAIN_CERT_PATH}/${DOMAIN_NAME}.crt
export DOMAIN_CERT_FULLCHAIN_FILE=${DOMAIN_CERT_PATH}/${DOMAIN_NAME}_fullchain.crt
export DOMAIN_CERT_FULLCHAIN_P12_FILE=${DOMAIN_CERT_PATH}/${DOMAIN_NAME}_fullchain.p12
export DOMAIN_CSR_FILE=${DOMAIN_CERT_PATH}/${DOMAIN_NAME}.csr

export DOMAIN_CSR_COMMON_NAME="*.${DOMAIN_NAME}"

export CERT_TYPE=

if [ -n ${DOMAIN_PRIVATE_PATH} ];then
  mkdir -p ${DOMAIN_PRIVATE_PATH}
fi

if [ -n ${DOMAIN_CERT_PATH} ];then
  mkdir -p ${DOMAIN_CERT_PATH}
fi

# 显示当前模式
if [ $USE_CA -eq 1 ]; then
    echo "Mode: Using CA signing"
    # 检查CA证书是否存在
    if [ ! -f ${CA_CERT_FILE} ] || [ ! -f ${CA_PRIVATE_FILE} ]; then
        echo "Error: CA certificate not found"
        echo "Please run generate_ca.sh first, or use --no-ca option"
        exit 1
    fi
else
    echo "Mode: Self-signed certificate (without CA)"
fi

# 从模板生成配置文件
echo "Generating OpenSSL config from template for domain: ${DOMAIN_NAME}"
sed "s/{{DOMAIN_NAME}}/${DOMAIN_NAME}/g" ${OPENSSL_CONFIG_TEMPLATE} > ${OPENSSL_CONFIG_FILE}

if [ ! -f ${OPENSSL_CONFIG_FILE} ]; then
    echo "Error: Failed to generate config file from template"
    exit 1
fi

# 条件判断 KEY_NAME 是否包含 '_ca'
if [[ "$CERT_TYPE" == "ca" ]]; then
  EXT_NAME="v3_ca"
else
  EXT_NAME="req_ext"
fi

# gen private key
echo "${DEFAULT_KEY_PASS}" | openssl genrsa -aes256 -passout stdin -out ${DOMAIN_PRIVATE_FILE} 2048
# gen csr
openssl req -new -sha256 -key ${DOMAIN_PRIVATE_FILE} -out ${DOMAIN_CSR_FILE} -config ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS} -subj "/CN=${DOMAIN_CSR_COMMON_NAME}"
# gen cer
if [ $USE_CA -eq 1 ]; then
    # CA签名模式
    echo "Signing certificate with CA..."
    openssl x509 -req -days ${EXPIRE_DAYS} -extensions ${EXT_NAME} -CA ${CA_CERT_FILE} -CAkey ${CA_PRIVATE_FILE} -CAserial ${CA_SRL_FILE} -CAcreateserial -in ${DOMAIN_CSR_FILE} -out ${DOMAIN_CERT_FILE} -extfile ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS}
else
    # 自签名模式
    echo "Creating self-signed certificate..."
    openssl x509 -req -days ${EXPIRE_DAYS} -extensions ${EXT_NAME} -signkey ${DOMAIN_PRIVATE_FILE} -in ${DOMAIN_CSR_FILE} -out ${DOMAIN_CERT_FILE} -extfile ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS}
fi
# show cer file
openssl x509 -noout -text -in ${DOMAIN_CERT_FILE}

# 根据模式生成fullchain和p12文件
if [ $USE_CA -eq 1 ]; then
    cat ${DOMAIN_CERT_FILE} ${CA_CERT_FILE}> ${DOMAIN_CERT_FULLCHAIN_FILE}
    openssl pkcs12 -export -out ${DOMAIN_CERT_FULLCHAIN_P12_FILE} -inkey ${DOMAIN_PRIVATE_FILE} -in ${DOMAIN_CERT_FILE} -passin pass:${CA_KEY_PASS} -password pass:${PK12_KEY_PASS} -certfile ${DOMAIN_CERT_FULLCHAIN_FILE}
else
    # 自签名模式：只包含证书本身
    cp ${DOMAIN_CERT_FILE} ${DOMAIN_CERT_FULLCHAIN_FILE}
    openssl pkcs12 -export -out ${DOMAIN_CERT_FULLCHAIN_P12_FILE} -inkey ${DOMAIN_PRIVATE_FILE} -in ${DOMAIN_CERT_FILE} -passin pass:${CA_KEY_PASS} -password pass:${PK12_KEY_PASS}
fi

# 去除key的密码
openssl rsa -in ${DOMAIN_PRIVATE_FILE} -out ${DOMAIN_PRIVATE_DECRYPTED_FILE} -passin pass:${DEFAULT_KEY_PASS}

# 清理临时生成的配置文件
echo "Cleaning up temporary config file: ${OPENSSL_CONFIG_FILE}"
rm -f ${OPENSSL_CONFIG_FILE}

# 显示完成信息
echo ""
echo "========================================"
echo "Certificate generation completed!"
echo "========================================"
echo ""
echo "Certificate files:"
echo "  Certificate: ${DOMAIN_CERT_FILE}"
echo "  Private Key: ${DOMAIN_PRIVATE_FILE}"
echo "  Private Key (no password): ${DOMAIN_PRIVATE_DECRYPTED_FILE}"
echo "  Full Chain: ${DOMAIN_CERT_FULLCHAIN_FILE}"
echo "  PKCS12: ${DOMAIN_CERT_FULLCHAIN_P12_FILE}"

if [ $USE_CA -eq 1 ]; then
    echo "  CA Certificate: ${CA_CERT_FILE}"
    echo ""
    echo "Usage instructions:"
    echo "  - Server: Use ${DOMAIN_CERT_FILE} and ${DOMAIN_PRIVATE_DECRYPTED_FILE}"
    echo "  - Client: Trust ${CA_CERT_FILE}"
else
    echo ""
    echo "Usage instructions:"
    echo "  - Server: Use ${DOMAIN_CERT_FILE} and ${DOMAIN_PRIVATE_DECRYPTED_FILE}"
    echo "  - Client: Trust ${DOMAIN_CERT_FILE} or skip verification (not recommended)"
fi
echo ""
