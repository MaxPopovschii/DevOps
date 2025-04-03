#!/bin/bash
# switch-context.sh - Script per passare facilmente tra gli ambienti

# Definizione dei colori per l'output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Percorsi degli ambienti disponibili
ENVS_DIR="$HOME/.ssl-environments"
CURRENT_ENV_FILE="$ENVS_DIR/.current"

# Assicurarsi che la directory degli ambienti esista
mkdir -p "$ENVS_DIR"

# Mostra l'ambiente corrente
show_current_env() {
    if [ -f "$CURRENT_ENV_FILE" ]; then
        current=$(cat "$CURRENT_ENV_FILE")
        echo -e "${YELLOW}Ambiente attuale:${NC} $current"
    else
        echo -e "${YELLOW}Nessun ambiente attualmente selezionato${NC}"
    fi
}

# Elenca tutti gli ambienti disponibili
list_environments() {
    echo -e "${YELLOW}Ambienti disponibili:${NC}"
    
    if [ -d "$ENVS_DIR" ]; then
        envs=$(find "$ENVS_DIR" -maxdepth 1 -type d -not -path "$ENVS_DIR" -exec basename {} \; | sort)
        
        if [ -z "$envs" ]; then
            echo "  Nessun ambiente configurato"
        else
            for env in $envs; do
                if [ -f "$CURRENT_ENV_FILE" ] && [ "$(cat "$CURRENT_ENV_FILE")" == "$env" ]; then
                    echo -e "  ${GREEN}* $env${NC} (attivo)"
                else
                    echo "  - $env"
                fi
            done
        fi
    else
        echo "  Nessun ambiente configurato"
    fi
}

# Crea un nuovo ambiente
create_environment() {
    env_name="$1"
    
    if [ -z "$env_name" ]; then
        read -p "Nome del nuovo ambiente: " env_name
    fi
    
    if [ -z "$env_name" ]; then
        echo "Nome ambiente non valido"
        exit 1
    fi
    
    env_path="$ENVS_DIR/$env_name"
    
    if [ -d "$env_path" ]; then
        echo "L'ambiente '$env_name' esiste già"
        exit 1
    fi
    
    mkdir -p "$env_path/certs" "$env_path/private" "$env_path/crl"
    echo "Ambiente '$env_name' creato con successo"
    
    # Chiedi se attivare subito il nuovo ambiente
    read -p "Vuoi attivare subito questo ambiente? (s/n): " activate
    if [[ "$activate" =~ ^[Ss]$ ]]; then
        switch_to "$env_name"
    fi
}

# Passa a un ambiente specifico
switch_to() {
    env_name="$1"
    
    if [ -z "$env_name" ]; then
        list_environments
        echo ""
        read -p "Seleziona l'ambiente: " env_name
    fi
    
    env_path="$ENVS_DIR/$env_name"
    
    if [ ! -d "$env_path" ]; then
        echo "L'ambiente '$env_name' non esiste"
        exit 1
    fi
    
    # Salva l'ambiente corrente
    echo "$env_name" > "$CURRENT_ENV_FILE"
    
    # Configura le variabili d'ambiente
    export SSL_ENV="$env_name"
    export SSL_CERT_DIR="$env_path/certs"
    export SSL_KEY_DIR="$env_path/private"
    export SSL_CRL_DIR="$env_path/crl"
    
    echo -e "${GREEN}Ambiente cambiato a:${NC} $env_name"
    echo "Eseguire il seguente comando per aggiornare l'ambiente nella shell corrente:"
    echo "source <(\"$0\" --export \"$env_name\")"
}

# Esporta le variabili d'ambiente per l'uso in source
export_env() {
    env_name="$1"
    
    if [ -z "$env_name" ]; then
        if [ -f "$CURRENT_ENV_FILE" ]; then
            env_name=$(cat "$CURRENT_ENV_FILE")
        else
            echo "Nessun ambiente selezionato" >&2
            exit 1
        fi
    fi
    
    env_path="$ENVS_DIR/$env_name"
    
    if [ ! -d "$env_path" ]; then
        echo "L'ambiente '$env_name' non esiste" >&2
        exit 1
    fi
    
    echo "export SSL_ENV=\"$env_name\""
    echo "export SSL_CERT_DIR=\"$env_path/certs\""
    echo "export SSL_KEY_DIR=\"$env_path/private\""
    echo "export SSL_CRL_DIR=\"$env_path/crl\""
    echo "echo -e \"${GREEN}Ambiente attivo:${NC} $env_name\""
}

# Rimuovi un ambiente
remove_environment() {
    env_name="$1"
    
    if [ -z "$env_name" ]; then
        list_environments
        echo ""
        read -p "Ambiente da rimuovere: " env_name
    fi
    
    env_path="$ENVS_DIR/$env_name"
    
    if [ ! -d "$env_path" ]; then
        echo "L'ambiente '$env_name' non esiste"
        exit 1
    fi
    
    # Chiedi conferma
    read -p "Sei sicuro di voler rimuovere l'ambiente '$env_name'? Questa operazione è irreversibile (s/n): " confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        echo "Operazione annullata"
        exit 0
    fi
    
    # Rimuovi l'ambiente
    rm -rf "$env_path"
    
    # Se l'ambiente corrente è stato rimosso, resetta
    if [ -f "$CURRENT_ENV_FILE" ] && [ "$(cat "$CURRENT_ENV_FILE")" == "$env_name" ]; then
        rm -f "$CURRENT_ENV_FILE"
        echo "L'ambiente corrente è stato rimosso"
    fi
    
    echo "Ambiente '$env_name' rimosso con successo"
}

# Mostra aiuto
show_help() {
    echo "Utilizzo: $(basename "$0") [opzione] [nome-ambiente]"
    echo ""
    echo "Opzioni:"
    echo "  -l, --list          Elenca gli ambienti disponibili"
    echo "  -c, --current       Mostra l'ambiente corrente"
    echo "  -s, --switch        Passa a un ambiente specifico"
    echo "  -n, --new           Crea un nuovo ambiente"
    echo "  -r, --remove        Rimuove un ambiente esistente"
    echo "  -e, --export        Esporta le variabili d'ambiente (usare con source)"
    echo "  -h, --help          Mostra questo aiuto"
    echo ""
    echo "Esempi:"
    echo "  $(basename "$0") --list             # Elenca tutti gli ambienti"
    echo "  $(basename "$0") --switch prod      # Passa all'ambiente 'prod'"
    echo "  $(basename "$0") --new test         # Crea un nuovo ambiente 'test'"
    echo "  source <($(basename "$0") --export) # Imposta le variabili nella shell corrente"
}

# Gestione argomenti
case "$1" in
    -l|--list)
        list_environments
        ;;
    -c|--current)
        show_current_env
        ;;
    -s|--switch)
        switch_to "$2"
        ;;
    -n|--new)
        create_environment "$2"
        ;;
    -r|--remove)
        remove_environment "$2"
        ;;
    -e|--export)
        export_env "$2"
        ;;
    -h|--help)
        show_help
        ;;
    *)
        if [ -z "$1" ]; then
            show_current_env
            echo ""
            list_environments
        else
            switch_to "$1"
        fi
        ;;
esac

exit 0
