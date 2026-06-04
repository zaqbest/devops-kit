#!/usr/bin/env bash
###############################################################
# 中间证书-Surge Root CA
###############################################################
export DEFAULT_KEY_PASS=123456
export CA_KEY_PASS=${DEFAULT_KEY_PASS}
export export PK12_KEY_PASS=${DEFAULT_KEY_PASS}

export EXPIRE_DAYS=3650
export OPENSSL_CONFIG_FILE=openssl.cnf.template
export CSR_COMMON_NAME="Surge Root CA"

export CA_ROOT_NAME=ca
export CA_CA_NAME=ca
export CA_PRIVATE_FILE=${CA_ROOT_NAME}/private/${CA_CA_NAME}.key
export CA_CERT_FILE=${CA_ROOT_NAME}/certs/${CA_CA_NAME}.crt
export CA_SRL_FILE=${CA_ROOT_NAME}/certs/${CA_CA_NAME}.srl

export APP_NAME=surge
export APP_ROOT_PATH=app/${APP_NAME}
export APP_PRIVATE_PATH=${APP_ROOT_PATH}/private
export APP_CERT_PATH=${APP_ROOT_PATH}/certs
export APP_PRIVATE_FILE=${APP_PRIVATE_PATH}/${APP_NAME}.key
export APP_CERT_FILE=${APP_CERT_PATH}/${APP_NAME}.crt
export APP_CERT_FULLCHAIN_FILE=${APP_CERT_PATH}/${APP_NAME}_fullchain.crt
export APP_CERT_FULLCHAIN_P12_FILE=${APP_CERT_PATH}/${APP_NAME}_fullchain.p12
export APP_CSR_FILE=${APP_CERT_PATH}/${APP_NAME}.csr

if [ -n ${APP_PRIVATE_PATH} ];then
  mkdir -p ${APP_PRIVATE_PATH}
fi

if [ -n ${APP_CERT_PATH} ];then
  mkdir -p ${APP_CERT_PATH}
fi


# gen private key
echo "${DEFAULT_KEY_PASS}" | openssl genrsa -aes256 -passout stdin -out ${APP_PRIVATE_FILE} 2048
# gen csr
openssl req -new -sha256 -key ${APP_PRIVATE_FILE} -out ${APP_CSR_FILE} -config ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS} -subj "/CN=${CSR_COMMON_NAME}"
# gen cer
openssl x509 -req -days ${EXPIRE_DAYS} -extensions v3_ca -CA ${CA_CERT_FILE} -CAkey ${CA_PRIVATE_FILE} -CAserial ${CA_SRL_FILE} -CAcreateserial -in ${APP_CSR_FILE} -out ${APP_CERT_FILE} -extfile ${OPENSSL_CONFIG_FILE} -passin pass:${DEFAULT_KEY_PASS}
# show cer file
openssl x509 -noout -text -in ${APP_CERT_FILE}

cat ${APP_CERT_FILE} ${CA_CERT_FILE} > ${APP_CERT_FULLCHAIN_FILE}

openssl pkcs12 -export -out ${APP_CERT_FULLCHAIN_P12_FILE} -inkey ${APP_PRIVATE_FILE} -in ${APP_CERT_FILE} -passin pass:${CA_KEY_PASS} -password pass:${PK12_KEY_PASS} -certfile ${APP_CERT_FULLCHAIN_FILE}
