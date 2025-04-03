#!/bin/bash
# renew-cert.sh - Script per rinnovare i certificati scaduti o in scadenza

# Definizione dei colori per l'output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Impostazioni predefinite
CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
KEY_DIR="${SSL_KEY_DIR:-/etc/ssl/private}"
CONFIG_DIR="$HOME/.ssl-config"
DEFAULT_CA_KEY="$KEY_DIR/ca.key"
DEFAULT_CA_CERT="$CERT_DIR/ca.crt"
DEFAULT_DAYS=365
DEFAULT_KEY_SIZE=2048
DEFAULT_DIGEST="sha256"

# Assicurarsi che la directory di configurazione esista
mkdir -p "$CONFIG_DIR"

# Funzione per generare un file di configurazione OpenSSL
generate_openssl_config() {
    local cert_type="$1"
    local common_name="$2"
    local output_file="$3"
    
    # Crea la directory se non esiste
    mkdir -p "$(dirname "$output_file")"
    
    # Inizia con la sezione richiesta
    cat > "$output_file" << EOF
[ req ]
default_bits = $DEFAULT_KEY_SIZE
default_md = $DEFAULT_DIGEST
distinguished_name = req_dn
req_extensions = req_ext
prompt = no

[ req_dn ]
CN = $common_name
EOF
    
    # Aggiungi campi opzionali se presenti
    if [ ! -z "$COUNTRY" ]; then
        echo "C = $COUNTRY" >> "$output_file"
    fi
    
    if [ ! -z "$STATE" ]; then
        echo "ST = $STATE" >> "$output_file"
    fi
    
    if [ ! -z "$LOCALITY" ]; then
        echo "L = $LOCALITY" >> "$output_file"
    fi
    
    if [ ! -z "$ORGANIZATION" ]; then
        echo "O = $ORGANIZATION" >> "$output_file"
    fi
    
    if [ ! -z "$ORG_UNIT" ]; then
        echo "OU = $ORG_UNIT" >> "$output_file"
    fi
    
    # Aggiungi la sezione delle estensioni in base al tipo di certificato
    echo "" >> "$output_file"
    echo "[ req_ext ]" >> "$output_file"
    
    case "$cert_type" in
        "server")
            cat >> "$output_file" << EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
EOF
            # Aggiungi il CN come DNS.1
            echo "DNS.1 = $common_name" >> "$output_file"
            
            # Aggiungi SAN aggiuntivi se presenti
            local i=2
            for san in "${SUBJECT_ALT_NAMES[@]}"; do
                echo "DNS.$i = $san" >> "$output_file"
                ((i++))
            done
            ;;
            
        "client")
            cat >> "$output_file" << EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
            ;;
            
        "ca")
            cat >> "$output_file" << EOF
basicConstraints = CA:TRUE
keyUsage = cRLSign, keyCertSign
EOF
            ;;
    esac
    
    echo -e "${BLUE}Configurazione OpenSSL generata in $output_file${NC}"
}

# Funzione per creare un certificato CA
create_ca_certificate() {
    local ca_key="$1"
    local ca_cert="$2"
    local common_name="$3"
    local days="$4"
    
    echo -e "${YELLOW}Creazione di un nuovo certificato CA...${NC}"
    
    # Genera un file di configurazione
    local config_file="$CONFIG_DIR/ca-config.cnf"
    generate_openssl_config "ca" "$common_name" "$config_file"
    
    # Crea directory per le chiavi private se non esistono
    mkdir -p "$(dirname "$ca_key")"
    
    # Crea la chiave privata
    openssl genrsa -out "$ca_key" $DEFAULT_KEY_SIZE
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore durante la generazione della chiave CA${NC}"
        return 1
    fi
    
    # Imposta i permessi corretti
    chmod 400 "$ca_key"
    
    # Crea la directory per i certificati se non esiste
    mkdir -p "$(dirname "$ca_cert")"
    
    # Crea il certificato CA auto-firmato
    openssl req -new -x509 -key "$ca_key" -out "$ca_cert" -config "$config_file" -days "$days"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore durante la generazione del certificato CA${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Certificato CA creato con successo:${NC}"
    echo "  - Chiave privata: $ca_key"
    echo "  - Certificato: $ca_cert"
    echo ""
    
    # Mostra le informazioni sul certificato
    echo -e "${BLUE}Informazioni sul certificato CA:${NC}"
    openssl x509 -in "$ca_cert" -noout -text | grep -E "Subject:|Issuer:|Validity|Not Before|Not After"
    
    return 0
}

# Funzione per rinnovare un certificato con CA esistente
renew_certificate() {
    local cert_type="$1"
    local common_name="$2"
    local output_cert="$3"
    local output_key="$4"
    local days="$5"
    local ca_key="$6"
    local ca_cert="$7"
    
    echo -e "${YELLOW}Rinnovo del certificato $common_name...${NC}"
    
    # Verifica l'esistenza del CA
    if [ ! -f "$ca_key" ] || [ ! -f "$ca_cert" ]; then
        echo -e "${RED}Errore: Certificato CA non trovato.${NC}"
        echo "Utilizza l'opzione --create-ca per creare un nuovo CA."
        return 1
    fi
    
    # Genera un file di configurazione
    local config_file="$CONFIG_DIR/${common_name//[^a-zA-Z0-9]/-}-config.cnf"
    generate_openssl_config "$cert_type" "$common_name" "$config_file"
    
    # Crea directory per le chiavi private se non esistono
    mkdir -p "$(dirname "$output_key")"
    
    # Crea la chiave privata
    openssl genrsa -out "$output_key" $DEFAULT_KEY_SIZE
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore durante la generazione della chiave${NC}"
        return 1
    fi
    
    # Imposta i permessi corretti
    chmod 400 "$output_key"
    
    # Crea la CSR (Certificate Signing Request)
    local temp_csr="$CONFIG_DIR/${common_name//[^a-zA-Z0-9]/-}.csr"
    openssl req -new -key "$output_key" -out "$temp_csr" -config "$config_file"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore durante la generazione della CSR${NC}"
        return 1
    fi
    
    # Crea la directory per i certificati se non esiste
    mkdir -p "$(dirname "$output_cert")"
    
    # Firma la CSR con il certificato CA
    openssl x509 -req -in "$temp_csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$output_cert" -days "$days" -extfile "$config_file" -extensions req_ext
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore durante la firma del certificato${NC}"
        return 1
    fi
    
    # Rimuovi la CSR temporanea
    rm -f "$temp_csr"
    
    echo -e "${GREEN}Certificato rinnovato con successo:${NC}"
    echo "  - Chiave privata: $output_key"
    echo "  - Certificato: $output_cert"
    echo ""
    
    # Mostra le informazioni sul certificato
    echo -e "${BLUE}Informazioni sul certificato:${NC}"
    openssl x509 -in "$output_cert" -noout -text | grep -E "Subject:|Issuer:|Validity|Not Before|Not After"
    
    return 0
}

# Funzione per verificare la validità di un certificato
check_certificate() {
    local cert_path="$1"
    
    if [ ! -f "$cert_path" ]; then
        # Certificato non esistente
        return 2
    fi
    
    # Verifica la data di scadenza
    local end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        # Non è un certificato valido
        return 3
    fi
    
    # Converti la data di scadenza in un formato utilizzabile
    local expiry=$(echo "$end_date" | sed 's/notAfter=//g')
    local expiry_seconds=$(date -d "$expiry" +%s 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        # Tenta di usare la sintassi alternativa per macOS
        expiry_seconds=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            # Impossibile analizzare la data
            return 4
        fi
    fi
    
    # Calcola i giorni rimanenti
    local current_seconds=$(date +%s)
    local seconds_left=$((expiry_seconds - current_seconds))
    local days_left=$((seconds_left / 86400))
    
    if [ $days_left -lt 0 ]; then
        # Certificato scaduto
        return 0
    else
        # Certificato valido, restituisci i giorni rimanenti
        echo "$days_left"
        return 1
    fi
}

# Mostra istruzioni per l'uso
show_usage() {
    echo "Utilizzo: $(basename "$0") [opzioni] [nome-comune]"
    echo ""
    echo "Opzioni:"
    echo "  -t, --type TYPE       Tipo di certificato (server, client, ca) [default: server]"
    echo "  -d, --days DAYS       Validità in giorni [default: $DEFAULT_DAYS]"
    echo "  --force               Forza il rinnovo anche se il certificato è ancora valido"
    echo "  --ca-key FILE         Percorso della chiave CA [default: $DEFAULT_CA_KEY]"
    echo "  --ca-cert FILE        Percorso del certificato CA [default: $DEFAULT_CA_CERT]"
    echo "  --create-ca           Crea un nuovo certificato CA"
    echo "  --cert-dir DIR        Directory per i certificati [default: $CERT_DIR]"
    echo "  --key-dir DIR         Directory per le chiavi private [default: $KEY_DIR]"
    echo "  -o, --output FILE     Nome del file di output (senza estensione)"
    echo "  --country CODE        Codice paese a due lettere (es. IT)"
    echo "  --state NAME          Stato o provincia"
    echo "  --locality NAME       Città o località"
    echo "  --org NAME            Nome dell'organizzazione"
    echo "  --org-unit NAME       Nome dell'unità organizzativa"
    echo "  --san DOMAIN          Aggiunge un Subject Alternative Name (può essere usato più volte)"
    echo "  -h, --help            Mostra questo messaggio di aiuto"
    echo ""
    echo "Esempi:"
    echo "  $(basename "$0") --create-ca \"My Root CA\"     # Crea una nuova CA"
    echo "  $(basename "$0") example.com                # Rinnova un certificato server"
    echo "  $(basename "$0") --type client user@example.com  # Crea un certificato client"
    echo "  $(basename "$0") --force --days 730 example.com  # Forza rinnovo con validità 2 anni"
    echo "  $(basename "$0") --san www.example.com --san mail.example.com example.com  # Con SAN"
}

# Variabili per le opzioni
CERT_TYPE="server"
DAYS="$DEFAULT_DAYS"
FORCE=false
CREATE_CA=false
OUTPUT_NAME=""
COMMON_NAME=""
