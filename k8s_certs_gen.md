# Kubernetes Certificate Management Guide
## Creating and Managing Long-Lived Certificates for Multiple Environments

## Table of Contents
1. [Introduction](#introduction)
2. [Architecture Overview](#architecture-overview)
3. [Creating a 50-Year Root CA](#creating-a-50-year-root-ca)
4. [Creating User Certificates](#creating-user-certificates)
   - [Admin Certificate (15 Years)](#admin-certificate-15-years)
   - [QA Developer Certificate (15 Years)](#qa-developer-certificate-15-years)
   - [External Developer Certificate (2 Years)](#external-developer-certificate-2-years)
5. [Configuring Kubernetes to Trust the CA](#configuring-kubernetes-to-trust-the-ca)
6. [Using the Same Certificates Across Environments](#using-the-same-certificates-across-environments)
7. [Certificate Rotation and Management](#certificate-rotation-and-management)
8. [Best Practices](#best-practices)
9. [Verification Process](#verification-process)
10. [Security Considerations](#security-considerations)

## Introduction

This document provides a detailed procedure for setting up a Public Key Infrastructure (PKI) for Kubernetes clusters, specifically addressing the following requirements:
- Creating a 50-year Root Certificate Authority (CA)
- Creating user-specific certificates with different validity periods:
  - Admin: 15 years
  - QA Developer: 15 years
  - External Developer: 2 years
- Using the same certificates across all environments (development, testing, production)

## Architecture Overview

Our certificate architecture will consist of:
1. A single Root CA valid for 50 years
2. User certificates signed by the Root CA with varying validity periods
3. Certificate configuration that works across multiple Kubernetes clusters

## Creating a 50-Year Root CA

First, let's create a 50-year Root CA certificate using OpenSSL:

```bash
# Create directory structure
mkdir -p k8s-pki/{ca,users,configs}
cd k8s-pki

# Generate a strong private key for the CA
openssl genrsa -out ca/ca.key 4096

# Create a CA certificate valid for 50 years (18262 days)
openssl req -x509 -new -nodes -key ca/ca.key -sha256 -days 18262 -out ca/ca.crt -subj "/CN=K8s-Enterprise-Root-CA/O=OurOrganization/OU=IT/C=US"
```

## Creating User Certificates

### Admin Certificate (15 Years)

```bash
# Generate key for admin
openssl genrsa -out users/admin.key 2048

# Create CSR (Certificate Signing Request)
openssl req -new -key users/admin.key -out users/admin.csr -subj "/CN=admin/O=system:masters/OU=IT/C=US"

# Create configuration file for the admin certificate
cat > configs/admin-cert.conf <<EOF
[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = admin
EOF

# Sign admin certificate with the CA, valid for 15 years (5475 days)
openssl x509 -req -in users/admin.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
  -out users/admin.crt -days 5475 -extensions v3_ext -extfile configs/admin-cert.conf
```

### QA Developer Certificate (15 Years)

```bash
# Generate key for QA Developer
openssl genrsa -out users/qa-dev.key 2048

# Create CSR
openssl req -new -key users/qa-dev.key -out users/qa-dev.csr -subj "/CN=qa-dev/O=development/OU=QA/C=US"

# Create configuration file for the QA Developer certificate
cat > configs/qa-dev-cert.conf <<EOF
[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = qa-dev
EOF

# Sign QA Developer certificate with the CA, valid for 15 years (5475 days)
openssl x509 -req -in users/qa-dev.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
  -out users/qa-dev.crt -days 5475 -extensions v3_ext -extfile configs/qa-dev-cert.conf
```

### External Developer Certificate (2 Years)

```bash
# Generate key for External Developer
openssl genrsa -out users/ext-dev.key 2048

# Create CSR
openssl req -new -key users/ext-dev.key -out users/ext-dev.csr -subj "/CN=ext-dev/O=contractors/OU=Development/C=US"

# Create configuration file for the External Developer certificate
cat > configs/ext-dev-cert.conf <<EOF
[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = ext-dev
EOF

# Sign External Developer certificate with the CA, valid for 2 years (730 days)
openssl x509 -req -in users/ext-dev.csr -CA ca/ca.crt -CAkey ca/ca.key -CAcreateserial \
  -out users/ext-dev.crt -days 730 -extensions v3_ext -extfile configs/ext-dev-cert.conf
```

## Configuring Kubernetes to Trust the CA

To make a Kubernetes cluster trust our custom CA, we need to add the CA certificate to the cluster's trusted CAs. This needs to be done for each cluster.

### 1. For Existing Clusters

```bash
# Assuming you have kubectl access as cluster-admin
kubectl config set-cluster my-cluster --certificate-authority=ca/ca.crt --embed-certs=true
```

### 2. For New Clusters (during kubeadm init)

When creating a new cluster with kubeadm, you can specify the CA:

```bash
# Copy the CA to the appropriate location
sudo mkdir -p /etc/kubernetes/pki/
sudo cp ca/ca.crt /etc/kubernetes/pki/ca.crt
sudo cp ca/ca.key /etc/kubernetes/pki/ca.key

# Initialize the cluster using the existing CA
sudo kubeadm init --cert-dir=/etc/kubernetes/pki
```

## Using the Same Certificates Across Environments

To use the same certificates across all environments, we'll create kubeconfig files for each user that can work with any cluster:

### Create Generic Kubeconfig for Admin

```bash
# Set up the admin kubeconfig
KUBECONFIG_DIR="kubeconfigs"
mkdir -p $KUBECONFIG_DIR

kubectl config set-cluster universal-cluster \
  --certificate-authority=ca/ca.crt \
  --embed-certs=true \
  --server=<SERVER_PLACEHOLDER> \
  --kubeconfig=$KUBECONFIG_DIR/admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=users/admin.crt \
  --client-key=users/admin.key \
  --embed-certs=true \
  --kubeconfig=$KUBECONFIG_DIR/admin.kubeconfig

kubectl config set-context admin@universal-cluster \
  --cluster=universal-cluster \
  --user=admin \
  --kubeconfig=$KUBECONFIG_DIR/admin.kubeconfig

kubectl config use-context admin@universal-cluster \
  --kubeconfig=$KUBECONFIG_DIR/admin.kubeconfig
```

### Create Generic Kubeconfigs for QA and External Developers

Similar steps can be followed to create kubeconfig files for QA and external developers, replacing the appropriate certificate and key files.

### Create Context Switch Script

To easily switch between environments, create a context switch script:

```bash
#!/bin/bash
# save as switch-context.sh

USER=$1
ENV=$2

if [ -z "$USER" ] || [ -z "$ENV" ]; then
  echo "Usage: $0 <user> <environment>"
  echo "Example: $0 admin production"
  exit 1
fi

SERVER=""
case $ENV in
  "dev")
    SERVER="https://k8s-dev.example.com:6443"
    ;;
  "test")
    SERVER="https://k8s-test.example.com:6443"
    ;;
  "prod")
    SERVER="https://k8s-prod.example.com:6443"
    ;;
  *)
    echo "Unknown environment: $ENV"
    exit 1
    ;;
esac

# Update the server in the kubeconfig file
sed -i "s|server:.*|server: $SERVER|g" kubeconfigs/$USER.kubeconfig

echo "Kubeconfig for $USER updated to use $ENV environment ($SERVER)"
```

## Certificate Rotation and Management

Even with long-lived certificates, it's important to plan for rotation:

### Certificate Expiry Monitoring

```bash
# Script to check certificate expiry (save as check-cert-expiry.sh)
#!/bin/bash

CERT_DIR="users"
WARNING_DAYS=180

for cert in $CERT_DIR/*.crt; do
  end_date=$(openssl x509 -enddate -noout -in $cert | cut -d= -f2)
  end_epoch=$(date -d "$end_date" +%s)
  now_epoch=$(date +%s)
  days_left=$(( (end_epoch - now_epoch) / 86400 ))
  
  echo "Certificate: $cert"
  echo "Expires on: $end_date"
  echo "Days left: $days_left"
  
  if [ $days_left -lt $WARNING_DAYS ]; then
    echo "WARNING: Certificate will expire in less than $WARNING_DAYS days!"
  fi
  
  echo "-------------------------"
done
```

### Certificate Renewal Process

When certificates need renewal:

1. Generate a new CSR using the existing key
2. Sign it with the CA for the appropriate duration
3. Distribute the new certificate to users

Example for renewing the external developer certificate:

```bash
# Create new CSR from existing key
openssl req -new -key users/ext-dev.key -out users/ext-dev-renewal.csr -subj "/CN=ext-dev/O=contractors/OU=Development/C=US"

# Sign with CA for another 2 years
openssl x509 -req -in users/ext-dev-renewal.csr -CA ca/ca.crt -CAkey ca/ca.key \
  -CAcreateserial -out users/ext-dev-renewed.crt -days 730 \
  -extensions v3_ext -extfile configs/ext-dev-cert.conf

# Replace the old certificate
mv users/ext-dev-renewed.crt users/ext-dev.crt
```

## Best Practices

1. **Secure Storage**: Store the Root CA private key offline in a secure location
2. **Backup**: Create secure backups of all certificate material
3. **Documentation**: Maintain documentation about certificate issuance and expiry
4. **Automation**: Automate certificate monitoring and renewal process
5. **Access Control**: Implement proper RBAC in Kubernetes to control what each certificate holder can do

## Verification Process

To verify that certificates are working across environments:

### 1. Test Authentication

```bash
# Test kubectl with the admin certificate
kubectl --kubeconfig=kubeconfigs/admin.kubeconfig get nodes

# Test kubectl with the QA developer certificate
kubectl --kubeconfig=kubeconfigs/qa-dev.kubeconfig get pods

# Test kubectl with the external developer certificate
kubectl --kubeconfig=kubeconfigs/ext-dev.kubeconfig get pods
```

### 2. Verify Certificate Details

```bash
# Verify certificate details
openssl x509 -in users/admin.crt -text -noout
```

### 3. Test with Different Contexts

```bash
# Switch environment and test
./switch-context.sh admin dev
kubectl --kubeconfig=kubeconfigs/admin.kubeconfig get pods

./switch-context.sh admin prod
kubectl --kubeconfig=kubeconfigs/admin.kubeconfig get pods
```

## Security Considerations

1. **Security Risk**: Long-lived certificates (especially 50 years) pose significant security risks
2. **Certificate Revocation**: Implement a Certificate Revocation List (CRL) or OCSP for revoking compromised certificates
3. **Regular Audits**: Regularly audit who has access to certificates
4. **Least Privilege**: Apply the principle of least privilege in RBAC policies

### Implementing Certificate Revocation

```bash
# Create a Certificate Revocation List (CRL)
openssl ca -gencrl -keyfile ca/ca.key -cert ca/ca.crt -out ca/ca.crl

# To revoke a certificate
openssl ca -revoke users/ext-dev.crt -keyfile ca/ca.key -cert ca/ca.crt

# Update the CRL after revoking
openssl ca -gencrl -keyfile ca/ca.key -cert ca/ca.crt -out ca/ca.crl
```

## Conclusion

This guide provides a comprehensive approach for implementing a certificate management system for Kubernetes that meets the specified requirements. While using the same certificates across all environments is technically possible, remember that it represents a security trade-off between convenience and the principle of isolation between environments.

The implementation described here creates a 50-year Root CA and user certificates with different validity periods. These certificates can be used across multiple Kubernetes environments through properly configured kubeconfig files.

Always consider security implications when implementing long-lived certificates and establish proper procedures for certificate management, monitoring, and revocation.
