#!/bin/bash
# Kubernetes Certificate Management PoC
# This script demonstrates how to create a long-lived root CA and user certificates
# for use across all Kubernetes environments.

set -e

# Create directory structure
mkdir -p ca/root-ca
mkdir -p ca/users/{admin,qa-developer,external-developer}
mkdir -p k8s-configs

# Step 1: Create a 50-year Root CA
echo "Creating 50-year Root CA..."

# Generate root CA private key
openssl genrsa -out ca/root-ca/ca.key 4096

# Generate root CA certificate (50 years validity)
openssl req -x509 -new -nodes -key ca/root-ca/ca.key -sha256 -days 18250 \
  -out ca/root-ca/ca.crt -subj "/CN=Kubernetes-Root-CA/O=Organization"

echo "Root CA created successfully with 50-year validity"

# Step 2: Create user certificates with different validities

# Function to create user certificates
create_user_cert() {
  local USER=$1
  local DAYS=$2
  local O=$3
  local CN="$USER"
  
  echo "Creating certificate for $USER with $DAYS days validity..."
  
  # Generate user private key
  openssl genrsa -out ca/users/$USER/$USER.key 2048
  
  # Generate user certificate signing request (CSR)
  openssl req -new -key ca/users/$USER/$USER.key -out ca/users/$USER/$USER.csr \
    -subj "/CN=$CN/O=$O"
  
  # Sign the user certificate using the Root CA
  openssl x509 -req -in ca/users/$USER/$USER.csr -CA ca/root-ca/ca.crt \
    -CAkey ca/root-ca/ca.key -CAcreateserial -out ca/users/$USER/$USER.crt \
    -days $DAYS -sha256
    
  # Create kubeconfig for the user
  KUBECONFIG_FILE="k8s-configs/kubeconfig-$USER"
  
  # Set cluster info
  kubectl config set-cluster kubernetes \
    --certificate-authority=ca/root-ca/ca.crt \
    --embed-certs=true \
    --server=https://kubernetes.example.com:6443 \
    --kubeconfig=$KUBECONFIG_FILE

  # Set user credentials
  kubectl config set-credentials $USER \
    --client-certificate=ca/users/$USER/$USER.crt \
    --client-key=ca/users/$USER/$USER.key \
    --embed-certs=true \
    --kubeconfig=$KUBECONFIG_FILE

  # Set context
  kubectl config set-context $USER-context \
    --cluster=kubernetes \
    --user=$USER \
    --namespace=default \
    --kubeconfig=$KUBECONFIG_FILE

  # Use the created context
  kubectl config use-context $USER-context --kubeconfig=$KUBECONFIG_FILE
  
  echo "Certificate for $USER created successfully"
}

# Create Admin certificate (15 years validity)
create_user_cert "admin" 5475 "system:masters"

# Create QA Developer certificate (15 years validity)
create_user_cert "qa-developer" 5475 "qa-developers"

# Create External Developer certificate (2 years validity)
create_user_cert "external-developer" 730 "external-developers"

# Step 3: Create RBAC configurations for different user roles
cat > k8s-configs/rbac-qa-developers.yaml <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: qa-developer-role
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "services", "deployments", "jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: qa-developer-binding
subjects:
- kind: Group
  name: qa-developers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: qa-developer-role
  apiGroup: rbac.authorization.k8s.io
EOF

cat > k8s-configs/rbac-external-developers.yaml <<EOF
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: external-developer-role
  namespace: external-dev
rules:
- apiGroups: ["", "apps"]
  resources: ["pods", "services", "deployments"]
  verbs: ["get", "list", "watch", "create", "update"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: external-developer-binding
  namespace: external-dev
subjects:
- kind: Group
  name: external-developers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: external-developer-role
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Created RBAC configurations for user roles"

# Step 4: Instructions for applying configurations to Kubernetes clusters
cat > README.md <<EOF
# Kubernetes Certificate Management PoC

This PoC demonstrates how to create and manage certificates for Kubernetes with a long-lived root CA
that works across all environments.

## Contents

- \`ca/root-ca/\` - Root CA certificates (50-year validity)
- \`ca/users/\` - User certificates with different validity periods
- \`k8s-configs/\` - Kubernetes configurations and RBAC rules

## How to Use

### 1. Distribute the Root CA to All Clusters

To use the same certificates across all environments, you need to distribute the Root CA certificate
to all Kubernetes clusters. Add the Root CA to the trusted CAs in each cluster's API server configuration.

For standard Kubernetes distributions, update the API server manifest to include:

\`\`\`yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    # other flags...
\`\`\`

For managed Kubernetes solutions:
- GKE: Use private cluster with custom CA
- EKS: Configure authentication through AWS IAM and map to Kubernetes RBAC
- AKS: Configure with Azure AD

### 2. Apply RBAC Configurations

Apply the RBAC configurations to each cluster:

\`\`\`bash
kubectl apply -f k8s-configs/rbac-qa-developers.yaml
kubectl apply -f k8s-configs/rbac-external-developers.yaml
\`\`\`

### 3. Distribute User Configurations

Distribute the appropriate kubeconfig files to your users:

- \`k8s-configs/kubeconfig-admin\` - For administrators (15-year validity)
- \`k8s-configs/kubeconfig-qa-developer\` - For QA developers (15-year validity)
- \`k8s-configs/kubeconfig-external-developer\` - For external developers (2-year validity)

### 4. Certificate Renewal

Before certificates expire, generate new certificates using the same Root CA:

\`\`\`bash
# Example for renewing an external developer certificate
openssl genrsa -out ca/users/external-developer/external-developer-renewed.key 2048
openssl req -new -key ca/users/external-developer/external-developer-renewed.key \
  -out ca/users/external-developer/external-developer-renewed.csr \
  -subj "/CN=external-developer/O=external-developers"
openssl x509 -req -in ca/users/external-developer/external-developer-renewed.csr \
  -CA ca/root-ca/ca.crt -CAkey ca/root-ca/ca.key -CAcreateserial \
  -out ca/users/external-developer/external-developer-renewed.crt \
  -days 730 -sha256
\`\`\`

## Security Considerations

1. Keep the Root CA private key (\`ca/root-ca/ca.key\`) highly secure, preferably offline
2. Consider implementing a certificate revocation mechanism for compromised certificates
3. Document certificate expiry dates and set up reminders for renewal
4. Implement automated certificate rotation for production systems

## Environment Independence

This setup ensures that certificates are not tied to specific environments because:

1. The same Root CA is trusted by all clusters
2. User certificates contain only user identity information, not environment-specific data
3. RBAC policies can be consistently applied across environments

EOF

echo "PoC setup complete. See README.md for usage instructions."
