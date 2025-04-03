#!/bin/bash
# Kubernetes Certificate Management Automation Script
# This script automates the creation of a 50-year Root CA and user certificates
# for Kubernetes with different validity periods.

set -e

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ROOT_CA_DAYS=18262 # 50 years
ADMIN_CERT_DAYS=5475 # 15 years
QA_DEV_CERT_DAYS=5475 # 15 years
EXT_DEV_CERT_DAYS=730 # 2 years

# Directory structure
BASE_DIR="k8s-pki"
CA_DIR="$BASE_DIR/ca"
USERS_DIR="$BASE_DIR/users"
CONFIGS_DIR="$BASE_DIR/configs"
KUBECONFIG_DIR="$BASE_DIR/kubeconfigs"

# Environment configuration
ENVIRONMENTS=(
  "dev:https://k8s-dev.example.com:6443"
  "test:https://k8s-test.example.com:6443"
  "prod:https://k8s-prod.example.com:6443"
)

# Create directories
echo -e "${BLUE}Creating directory structure...${NC}"
mkdir -p "$CA_DIR" "$USERS_DIR" "$CONFIGS_DIR" "$KUBECONFIG_DIR"

# Create Root CA
create_root_ca() {
  echo -e "${BLUE}Creating Root CA (valid for 50 years)...${NC}"
  
  if [ -f "$CA_DIR/ca.key" ] && [ -f "$CA_DIR/ca.crt" ]; then
    echo -e "${YELLOW}Root CA already exists. Skipping creation.${NC}"
    return
  fi
  
  openssl genrsa -out "$CA_DIR/ca.key" 4096
  
  openssl req -x509 -new -nodes -key "$CA_DIR/ca.key" -sha256 -days $ROOT_CA_DAYS \
    -out "$CA_DIR/ca.crt" -subj "/CN=K8s-Enterprise-Root-CA/O=OurOrganization/OU=IT/C=US"
  
  echo -e "${GREEN}Root CA created successfully.${NC}"
}

# Create user certificate
create_user_cert() {
  local USER=$1
  local DAYS=$2
  local O=$3
  local OU=$4
  
  echo -e "${BLUE}Creating certificate for $USER (valid for $(($DAYS / 365)) years)...${NC}"
  
  if [ -f "$USERS_DIR/$USER.key" ] && [ -f "$USERS_DIR/$USER.crt" ]; then
    echo -e "${YELLOW}Certificate for $USER already exists. Skipping creation.${NC}"
    return
  fi
  
  # Generate key
  openssl genrsa -out "$USERS_DIR/$USER.key" 2048
  
  # Create CSR
  openssl req -new -key "$USERS_DIR/$USER.key" -out "$USERS_DIR/$USER.csr" \
    -subj "/CN=$USER/O=$O/OU=$OU/C=US"
  
  # Create config file
  cat > "$CONFIGS_DIR/$USER-cert.conf" <<EOF
[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1 = $USER
EOF
  
  # Sign certificate with CA
  openssl x509 -req -in "$USERS_DIR/$USER.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial -out "$USERS_DIR/$USER.crt" -days $DAYS \
    -extensions v3_ext -extfile "$CONFIGS_DIR/$USER-cert.conf"
  
  echo -e "${GREEN}Certificate for $USER created successfully.${NC}"
}

# Create kubeconfig for user
create_kubeconfig() {
  local USER=$1
  local ENV=$2
  local SERVER=$3
  
  echo -e "${BLUE}Creating kubeconfig for $USER in $ENV environment...${NC}"
  
  # Set up cluster
  kubectl config set-cluster "k8s-$ENV" \
    --certificate-authority="$CA_DIR/ca.crt" \
    --embed-certs=true \
    --server="$SERVER" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-$ENV.kubeconfig"
  
  # Set up user
  kubectl config set-credentials "$USER" \
    --client-certificate="$USERS_DIR/$USER.crt" \
    --client-key="$USERS_DIR/$USER.key" \
    --embed-certs=true \
    --kubeconfig="$KUBECONFIG_DIR/$USER-$ENV.kubeconfig"
  
  # Set up context
  kubectl config set-context "$USER@k8s-$ENV" \
    --cluster="k8s-$ENV" \
    --user="$USER" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-$ENV.kubeconfig"
  
  # Use context
  kubectl config use-context "$USER@k8s-$ENV" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-$ENV.kubeconfig"
  
  echo -e "${GREEN}Kubeconfig for $USER in $ENV environment created successfully.${NC}"
}

# Create universal kubeconfig for user (with placeholder server)
create_universal_kubeconfig() {
  local USER=$1
  
  echo -e "${BLUE}Creating universal kubeconfig for $USER...${NC}"
  
  # Set up cluster with placeholder
  kubectl config set-cluster "universal-cluster" \
    --certificate-authority="$CA_DIR/ca.crt" \
    --embed-certs=true \
    --server="https://PLACEHOLDER:6443" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-universal.kubeconfig"
  
  # Set up user
  kubectl config set-credentials "$USER" \
    --client-certificate="$USERS_DIR/$USER.crt" \
    --client-key="$USERS_DIR/$USER.key" \
    --embed-certs=true \
    --kubeconfig="$KUBECONFIG_DIR/$USER-universal.kubeconfig"
  
  # Set up context
  kubectl config set-context "$USER@universal-cluster" \
    --cluster="universal-cluster" \
    --user="$USER" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-universal.kubeconfig"
  
  # Use context
  kubectl config use-context "$USER@universal-cluster" \
    --kubeconfig="$KUBECONFIG_DIR/$USER-universal.kubeconfig"
  
  echo -e "${GREEN}Universal kubeconfig for $USER created successfully.${NC}"
}

# Create context switch script
create_context_switch_script() {
  echo -e "${BLUE}Creating context switch script...${NC}"
  
  cat > "$BASE_DIR/switch-context.sh" <<'EOF'
#!/bin/bash
# K8s Context Switch Script

USER=$1
ENV=$2

if [ -z "$USER" ] || [ -z "$ENV" ]; then
  echo "Usage: $0 <user> <environment>"
  echo "Example: $0 admin production"
  exit 1
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
KUBECONFIG_FILE="$SCRIPT_DIR/kubeconfigs/$USER-universal.kubeconfig"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "Error: Kubeconfig for user $USER not found."
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
    echo "Valid environments: dev, test, prod"
    exit 1
    ;;
esac

# Update the server in the kubeconfig file
sed -i "s|server: https://[^:]*:6443|server: $SERVER|g" "$KUBECONFIG_FILE"

echo "Kubeconfig for $USER updated to use $ENV environment ($SERVER)"
echo "Use it with: kubectl --kubeconfig=$KUBECONFIG_FILE get pods"
EOF
  
  chmod +x "$BASE_DIR/switch-context.sh"
  echo -e "${GREEN}Context switch script created successfully.${NC}"
}

# Create certificate expiry monitoring script
create_cert_monitor_script() {
  echo -e "${BLUE}Creating certificate monitoring script...${NC}"
  
  cat > "$BASE_DIR/check-cert-expiry.sh" <<'EOF'
#!/bin/bash
# Certificate Expiry Monitoring Script

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CERT_DIR="$SCRIPT_DIR/users"
WARNING_DAYS=180

if [ ! -d "$CERT_DIR" ]; then
  echo "Error: Certificate directory not found."
  exit 1
fi

echo "Checking certificate expiry dates..."
echo "--------------------------------------"

for cert in "$CERT_DIR"/*.crt; do
  if [ ! -f "$cert" ]; then
    echo "No certificates found."
    exit 0
  fi
  
  cert_name=$(basename "$cert")
  end_date=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
  end_epoch=$(date -d "$end_date" +%s)
  now_epoch=$(date +%s)
  days_left=$(( (end_epoch - now_epoch) / 86400 ))
  
  echo "Certificate: $cert_name"
  echo "Expires on: $end_date"
  echo "Days left: $days_left"
  
  if [ $days_left -lt $WARNING_DAYS ]; then
    echo "WARNING: Certificate will expire in less than $WARNING_DAYS days!"
  fi
  
  echo "--------------------------------------"
done
EOF
  
  chmod +x "$BASE_DIR/check-cert-expiry.sh"
  echo -e "${GREEN}Certificate monitoring script created successfully.${NC}"
}

# Create certificate renewal script
create_cert_renewal_script() {
  echo -e "${BLUE}Creating certificate renewal script...${NC}"
  
  cat > "$BASE_DIR/renew-cert.sh" <<'EOF'
#!/bin/bash
# Certificate Renewal Script

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
USERS_DIR="$SCRIPT_DIR/users"
CONFIGS_DIR="$SCRIPT_DIR/configs"
CA_DIR="$SCRIPT_DIR/ca"

USER=$1
DAYS=$2

if [ -z "$USER" ] || [ -z "$DAYS" ]; then
  echo "Usage: $0 <user> <days>"
  echo "Example: $0 ext-dev 730"
  exit 1
fi

if [ ! -f "$USERS_DIR/$USER.key" ]; then
  echo "Error: Key for user $USER not found."
  exit 1
fi

if [ ! -f "$CONFIGS_DIR/$USER-cert.conf" ]; then
  echo "Error: Config for user $USER not found."
  exit 1
fi

# Get user info from existing cert
CN=$(openssl x509 -in "$USERS_DIR/$USER.crt" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
O=$(openssl x509 -in "$USERS_DIR/$USER.crt" -noout -subject | sed -n 's/.*O = \([^,]*\).*/\1/p')
OU=$(openssl x509 -in "$USERS_DIR/$USER.crt" -noout -subject | sed -n 's/.*OU = \([^,]*\).*/\1/p')

echo "Renewing certificate for $USER (CN=$CN, O=$O, OU=$OU) for $DAYS days..."

# Create new CSR from existing key
openssl req -new -key "$USERS_DIR/$USER.key" -out "$USERS_DIR/$USER-renewal.csr" \
  -subj "/CN=$CN/O=$O/OU=$OU/C=US"

# Sign with CA
openssl x509 -req -in "$USERS_DIR/$USER-renewal.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -CAcreateserial -out "$USERS_DIR/$USER-renewed.crt" -days $DAYS \
  -extensions v3_ext -extfile "$CONFIGS_DIR/$USER-cert.conf"

# Backup old certificate
mv "$USERS_DIR/$USER.crt" "$USERS_DIR/$USER.crt.bak.$(date +%Y%m%d)"

# Replace with new certificate
mv "$USERS_DIR/$USER-renewed.crt" "$USERS_DIR/$USER.crt"

# Clean up
rm "$USERS_DIR/$USER-renewal.csr"

echo "Certificate for $USER renewed successfully."
echo "Old certificate backed up as $USER.crt.bak.$(date +%Y%m%d)"
echo "You may need to recreate kubeconfig files to use the new certificate."
EOF
  
  chmod +x "$BASE_DIR/renew-cert.sh"
  echo -e "${GREEN}Certificate renewal script created successfully.${NC}"
}

# Create CRL management script
create_crl_script() {
  echo -e "${BLUE}Creating CRL management script...${NC}"
  
  cat > "$BASE_DIR/manage-crl.sh" <<'EOF'
#!/bin/bash
# Certificate Revocation List Management Script

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
USERS_DIR="$SCRIPT_DIR/users"
CA_DIR="$SCRIPT_DIR/ca"
INDEX_FILE="$CA_DIR/index.txt"
SERIAL_FILE="$CA_DIR/serial"
CRL_FILE="$CA_DIR/ca.crl"

# Initialize CA database if needed
initialize_ca_db() {
  if [ ! -f "$INDEX_FILE" ]; then
    touch "$INDEX_FILE"
    echo "01" > "$SERIAL_FILE"
    
    # Create openssl configuration
    cat > "$CA_DIR/openssl.cnf" <<EOT
[ ca ]
default_ca = CA_default

[ CA_default ]
dir = $CA_DIR
database = $INDEX_FILE
serial = $SERIAL_FILE
new_certs_dir = $CA_DIR/newcerts
certificate = $CA_DIR/ca.crt
private_key = $CA_DIR/ca.key
default_md = sha256
default_crl_days = 30
policy = policy_any

[ policy_any ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
EOT

    # Create directory for new certificates
    mkdir -p "$CA_DIR/newcerts"
  fi
}

ACTION=$1
CERT_NAME=$2

if [ "$ACTION" != "generate" ] && [ "$ACTION" != "revoke" ] && [ "$ACTION" != "list" ]; then
  echo "Usage: $0 <action> [cert_name]"
  echo "Actions:"
  echo "  generate - Generate a new CRL"
  echo "  revoke <cert_name> - Revoke a certificate"
  echo "  list - List all revoked certificates"
  exit 1
fi

# Initialize CA database
initialize_ca_db

case $ACTION in
  "generate")
    echo "Generating CRL..."
    openssl ca -gencrl -config "$CA_DIR/openssl.cnf" -out "$CRL_FILE"
    echo "CRL generated: $CRL_FILE"
    ;;
    
  "revoke")
    if [ -z "$CERT_NAME" ]; then
      echo "Error: Certificate name required for revoke action."
      exit 1
    fi
    
    CERT_PATH="$USERS_DIR/$CERT_NAME.crt"
    
    if [ ! -f "$CERT_PATH" ]; then
      echo "Error: Certificate $CERT_NAME not found."
      exit 1
    }
    
    echo "Revoking certificate: $CERT_NAME"
    openssl ca -config "$CA_DIR/openssl.cnf" -revoke "$CERT_PATH"
    
    # Generate a new CRL after revocation
    echo "Generating updated CRL..."
    openssl ca -gencrl -config "$CA_DIR/openssl.cnf" -out "$CRL_FILE"
    
    echo "Certificate $CERT_NAME revoked successfully."
    echo "CRL updated: $CRL_FILE"
    ;;
    
  "list")
    echo "Revoked certificates:"
    openssl crl -in "$CRL_FILE" -text -noout | grep "Serial Number" -A1
    ;;
esac
EOF
  
  chmod +x "$BASE_DIR/manage-crl.sh"
  echo -e "${GREEN}CRL management script created successfully.${NC}"
}

# Main execution
echo -e "${BLUE}Starting K8s Certificate Management Setup...${NC}"

create_root_ca

# Create user certificates
create_user_cert "admin" $ADMIN_CERT_DAYS "system:masters" "IT"
create_user_cert "qa-dev" $QA_DEV_CERT_DAYS "development" "QA"
create_user_cert "ext-dev" $EXT_DEV_CERT_DAYS "contractors" "Development"

# Create universal kubeconfigs
create_universal_kubeconfig "admin"
create_universal_kubeconfig "qa-dev"
create_universal_kubeconfig "ext-dev"

# Create environment-specific kubeconfigs
for env_config in "${ENVIRONMENTS[@]}"; do
  IFS=':' read -ra ENV_PARTS <<< "$env_config"
  ENV="${ENV_PARTS[0]}"
  SERVER="${ENV_PARTS[1]}"
  
  create_kubeconfig "admin" "$ENV" "$SERVER"
  create_kubeconfig "qa-dev" "$ENV" "$SERVER"
  create_kubeconfig "ext-dev" "$ENV" "$SERVER"
done

# Create utility scripts
create_context_switch_script
create_cert_monitor_script
create_cert_renewal_script
create_crl_script

echo -e "${GREEN}K8s Certificate Management Setup completed successfully!${NC}"
echo ""
echo -e "${BLUE}Available kubeconfig files:${NC}"
ls -la "$KUBECONFIG_DIR"
echo ""
echo -e "${BLUE}Utility scripts:${NC}"
echo "$BASE_DIR/switch-context.sh - Switch between environments with universal kubeconfig"
echo "$BASE_DIR/check-cert-expiry.sh - Check certificate expiry dates"
echo "$BASE_DIR/renew-cert.sh - Renew a certificate"
echo "$BASE_DIR/manage-crl.sh - Manage Certificate Revocation List"
echo ""
echo -e "${YELLOW}Before using in production:${NC}"
echo "1. Update the server URLs in the script to match your environment"
echo "2. Test the certificates thoroughly in a development environment"
echo "3. Make sure to secure the Root CA private key"
echo "4. Configure appropriate RBAC rules for each user in Kubernetes"
