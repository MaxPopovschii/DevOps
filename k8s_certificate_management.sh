#!/bin/bash

set -e

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CERT_DIR="/root/k8s-pki"
KUBECONFIG_DIR="${CERT_DIR}/kubeconfigs"
TEMP_DIR="/tmp/k8s-certs"
CA_CERT="/etc/kubernetes/pki/ca.crt"
CA_KEY="/etc/kubernetes/pki/ca.key"

# Create required directories
mkdir -p "${CERT_DIR}" "${KUBECONFIG_DIR}" "${TEMP_DIR}"

# Check for CA certificates
echo -e "${BLUE}Checking cluster CA certificates...${NC}"
if [ ! -f "${CA_CERT}" ] || [ ! -f "${CA_KEY}" ]; then
    echo -e "${RED}Error: Cluster CA certificates not found!${NC}"
    exit 1
fi

generate_user_cert() {
    local USERNAME=$1
    local GROUP=$2
    
    echo -e "${BLUE}Generating certificates for user: ${USERNAME}${NC}"
    
    # Generate private key
    openssl genrsa -out "${TEMP_DIR}/${USERNAME}.key" 2048
    
    # Create config file for CSR
    cat > "${TEMP_DIR}/${USERNAME}-csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${USERNAME}
EOF
    
    # Generate CSR
    openssl req -new \
        -key "${TEMP_DIR}/${USERNAME}.key" \
        -subj "/CN=${USERNAME}/O=${GROUP}" \
        -config "${TEMP_DIR}/${USERNAME}-csr.conf" \
        -out "${TEMP_DIR}/${USERNAME}.csr"
    
    # Sign certificate with cluster CA
    openssl x509 -req \
        -in "${TEMP_DIR}/${USERNAME}.csr" \
        -CA "${CA_CERT}" \
        -CAkey "${CA_KEY}" \
        -CAcreateserial \
        -out "${TEMP_DIR}/${USERNAME}.crt" \
        -days 365 \
        -extensions v3_req \
        -extfile "${TEMP_DIR}/${USERNAME}-csr.conf"
    
    # Create kubeconfig
    kubectl config set-cluster kubernetes \
        --certificate-authority="${CA_CERT}" \
        --embed-certs=true \
        --server=https://controlplane:6443 \
        --kubeconfig="${TEMP_DIR}/${USERNAME}.kubeconfig"
    
    kubectl config set-credentials "${USERNAME}" \
        --client-certificate="${TEMP_DIR}/${USERNAME}.crt" \
        --client-key="${TEMP_DIR}/${USERNAME}.key" \
        --embed-certs=true \
        --kubeconfig="${TEMP_DIR}/${USERNAME}.kubeconfig"
    
    kubectl config set-context "${USERNAME}@kubernetes" \
        --cluster=kubernetes \
        --user="${USERNAME}" \
        --kubeconfig="${TEMP_DIR}/${USERNAME}.kubeconfig"
    
    kubectl config use-context "${USERNAME}@kubernetes" \
        --kubeconfig="${TEMP_DIR}/${USERNAME}.kubeconfig"
    
    # Move files to final location
    mv "${TEMP_DIR}/${USERNAME}.key" "${CERT_DIR}/${USERNAME}.key"
    mv "${TEMP_DIR}/${USERNAME}.crt" "${CERT_DIR}/${USERNAME}.crt"
    mv "${TEMP_DIR}/${USERNAME}.kubeconfig" "${KUBECONFIG_DIR}/${USERNAME}.kubeconfig"
    
    # Set proper permissions
    chmod 600 "${CERT_DIR}/${USERNAME}.key"
    chmod 644 "${CERT_DIR}/${USERNAME}.crt"
    chmod 600 "${KUBECONFIG_DIR}/${USERNAME}.kubeconfig"
    
    echo -e "${GREEN}Successfully generated certificates for ${USERNAME}${NC}"
}

# Generate certificates for different users
generate_user_cert "admin" "system:masters"
generate_user_cert "developer" "development"
generate_user_cert "viewer" "view-only"

# Clean up temporary files
rm -rf "${TEMP_DIR}"

echo -e "${GREEN}Certificate generation completed successfully!${NC}"
echo -e "${BLUE}Kubeconfig files are available in: ${KUBECONFIG_DIR}${NC}"
ls -l "${KUBECONFIG_DIR}"
