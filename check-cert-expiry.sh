#!/bin/bash
# check-cert-expiry.sh - Script per monitorare le date di scadenza dei certificati

# Definizione dei colori per l'output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Impostazione dei giorni di avviso
WARNING_DAYS=30
CRITICAL_DAYS=7

# Directory default per i certificati
DEFAULT_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

# Funzione per controllare un singolo certificato
check_cert() {
    local cert_path="$1"
    local cert_name=$(basename "$cert_path")
    
    # Controlla che il file esista e sia un certificato valido
    if [ ! -f "$cert_path" ]; then
        echo -e "${RED}Errore: Il file $cert_path non esiste${NC}"
        return 1
    fi
    
    # Estrai la data di scadenza
    local end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Errore: $cert_path non è un certificato valido${NC}"
        return 1
    fi
    
    # Converti la data di scadenza in un formato utilizzabile
    local expiry=$(echo "$end_date" | sed 's/notAfter=//g')
    local expiry_seconds=$(date -d "$expiry" +%s 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        # Tenta di usare la sintassi alternativa per macOS
        expiry_seconds=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}Errore: Impossibile analizzare la data di scadenza per $cert_path${NC}"
            return 1
        fi
    fi
    
    # Calcola i giorni rimanenti
    local current_seconds=$(date +%s)
    local seconds_left=$((expiry_seconds - current_seconds))
    local days_left=$((seconds_left / 86400))
    
    # Estrai informazioni sul certificato
    local subject=$(openssl x509 -subject -noout -in "$cert_path" | sed 's/subject=//g')
    local issuer=$(openssl x509 -issuer -noout -in "$cert_path" | sed 's/issuer=//g')
    
    # Stampa il risultato con il colore appropriato
    local status
    local color
    
    if [ $days_left -lt 0 ]; then
        status="SCADUTO"
        color=$RED
    elif [ $days_left -lt $CRITICAL_DAYS ]; then
        status="CRITICO"
        color=$RED
    elif [ $days_left -lt $WARNING_DAYS ]; then
        status="AVVISO"
        color=$YELLOW
    else
        status="VALIDO"
        color=$GREEN
    fi
    
    printf "${color}%-10s${NC} %-40s %s giorni rimasti (scade il %s)\n" "[$status]" "$cert_name" "$days_left" "$expiry"
    
    # Stampa dettagli aggiuntivi se richiesto
    if [ "$VERBOSE" == "true" ]; then
        echo "  Soggetto: $subject"
        echo "  Emesso da: $issuer"
        echo "  Percorso completo: $cert_path"
        echo ""
    fi
    
    # Restituisci il numero di giorni per ordinare
    echo "$days_left" > /dev/null
    return $days_left
}

# Funzione per controllare tutti i certificati in una directory
check_certs_in_dir() {
    local cert_dir="$1"
    local sort_by="$2"
    
    if [ ! -d "$cert_dir" ]; then
        echo -e "${RED}Errore: La directory $cert_dir non esiste${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Controllo certificati in $cert_dir:${NC}"
    echo ""
    
    # Trova tutti i file nella directory 
    local cert_files=()
    while IFS= read -r -d '' file; do
        # Verifica veloce se è un file certificato
        if openssl x509 -noout -in "$file" &>/dev/null; then
            cert_files+=("$file")
        fi
    done < <(find "$cert_dir" -type f -print0)
    
    # Se non ci sono certificati
    if [ ${#cert_files[@]} -eq 0 ]; then
        echo "Nessun certificato valido trovato nella directory"
        return
    fi
    
    # Array per contenere i risultati con i giorni per l'ordinamento
    declare -A results
    
    # Controlla ogni certificato
    for cert in "${cert_files[@]}"; do
        # Salva l'output del controllo
        local output=$(check_cert "$cert")
        local days=$?
        
        # Salva il risultato con i giorni come chiave per l'ordinamento
        results["$days"]="$output"
    done
    
    # Stampa i risultati ordinati per numero di giorni rimanenti
    if [ "$sort_by" == "expiry" ]; then
        # Ordina per data di scadenza (ascendente)
        for days in $(echo "${!results[@]}" | tr ' ' '\n' | sort -n); do
            echo -e "${results[$days]}"
        done
    else
        # Nessun ordinamento specifico, usa l'ordine dei file
        for cert in "${cert_files[@]}"; do
            local output=$(check_cert "$cert")
            echo -e "$output"
        done
    fi
}

# Mostra istruzioni per l'uso
show_usage() {
    echo "Utilizzo: $(basename "$0") [opzioni] [percorso/file.crt | directory]"
    echo ""
    echo "Opzioni:"
    echo "  -d, --directory DIR  Controlla tutti i certificati nella directory specificata"
    echo "  -w, --warning DAYS   Imposta la soglia di avviso (default: $WARNING_DAYS giorni)"
    echo "  -c, --critical DAYS  Imposta la soglia critica (default: $CRITICAL_DAYS giorni)"
    echo "  -s, --sort-expiry    Ordina per data di scadenza (dal più vicino alla scadenza)"
    echo "  -v, --verbose        Mostra informazioni dettagliate sui certificati"
    echo "  -h, --help           Mostra questo messaggio di aiuto"
    echo ""
    echo "Se non viene specificato alcun percorso, verrà controllata la directory predefinita:"
    echo "  $DEFAULT_CERT_DIR"
    echo ""
    echo "Esempi:"
    echo "  $(basename "$0") certificato.crt        # Controlla un solo certificato"
    echo "  $(basename "$0") -d /etc/ssl/certs      # Controlla tutti i certificati in una directory"
    echo "  $(basename "$0") -v -s -w 60 -c 14      # Modifica soglie e mostra dettagli"
}

# Opzioni predefinite
SORT_BY=""
VERBOSE=false
CHECK_DIR=false
TARGET_PATH=""

# Parsing degli argomenti
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--directory)
            CHECK_DIR=true
            TARGET_PATH="$2"
            shift 2
            ;;
        -w|--warning)
            WARNING_DAYS="$2"
            shift 2
            ;;
        -c|--critical)
            CRITICAL_DAYS="$2"
            shift 2
            ;;
        -s|--sort-expiry)
            SORT_BY="expiry"
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            TARGET_PATH="$1"
            shift
            ;;
    esac
done

# Se non è stato specificato un percorso, usa la directory predefinita
if [ -z "$TARGET_PATH" ]; then
    TARGET_PATH="$DEFAULT_CERT_DIR"
    CHECK_DIR=true
fi

# Controlla se il percorso è una directory o un file
if [ -d "$TARGET_PATH" ] || [ "$CHECK_DIR" = true ]; then
    check_certs_in_dir "$TARGET_PATH" "$SORT_BY"
elif [ -f "$TARGET_PATH" ]; then
    check_cert "$TARGET_PATH"
else
    echo -e "${RED}Errore: Il percorso specificato non esiste${NC}"
    exit 1
fi

exit 0
