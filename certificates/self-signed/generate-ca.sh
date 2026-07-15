#!/usr/bin/env bash

###############################################################
# ZAQ Root CA
###############################################################
# 生成CA key
export DEFAULT_KEY_PASS=123456
export OPENSSL_CONFIG_FILE=openssl.cnf.template
export EXPIRE_DAYS=36500
export ROOT_NAME=ca
export CA_NAME=ca
export PRIVATE_FILE=${ROOT_NAME}/private/${CA_NAME}.key
export CERT_FILE=${ROOT_NAME}/certs/${CA_NAME}.crt
export CSR_FILE=${ROOT_NAME}/certs/${CA_NAME}.csr
echo "${DEFAULT_KEY_PASS}" | openssl genrsa -aes256 -passout stdin -out ${PRIVATE_FILE} 2048

# 生成 CSR
openssl req -new -sha256 -key ${PRIVATE_FILE} -out ${CSR_FILE} -config ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS} -subj "/CN=ZAQ Root CA"

# 生成证书
openssl x509 -req -days ${EXPIRE_DAYS} -extensions v3_ca -signkey ${PRIVATE_FILE} -in ${CSR_FILE} -out ${CERT_FILE} -extfile ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS}

# 清理CSR
rm -rf ${CSR_FILE}

# 查看证书
openssl x509 -noout -text -in ${CERT_FILE}
