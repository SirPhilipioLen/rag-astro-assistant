#!/bin/bash

export DOCKER_CLI_HINTS=false

echo "==================================================="
echo "           Starting RAG Astro-Assistant"
echo "==================================================="
echo

# === NATIVE LINUX CONFIGURATION ===
export OLLAMA_HOST="http://localhost:11434"
export CONTAINER_OLLAMA_HOST="http://172.17.0.1:11434"


# === ΣΥΝΑΡΤΗΣΕΙΣ ===

chk_ol() {
    if ! command -v ollama >/dev/null 2>&1; then
        echo "[WARNING] Ollama was not found."
        read -p "Would you like to install Ollama automatically? (y/n): " install_ollama
        if [[ "${install_ollama,,}" == "y" ]]; then
            echo "[INFO] Installing Ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            echo "[SUCCESS] Ollama installed successfully."
        else
            echo "[ERROR] Ollama is required."
            exit 1
        fi
    fi
}

chk_svc() {
    echo "[INFO] Checking if Ollama background service is active..."
    
    # 1. Έλεγχος αν το Ollama τρέχει γενικά στο σύστημα
    if ! curl -s http://localhost:11434 >/dev/null 2>&1; then
        echo "[WARNING] Ollama service is not running."
        read -p "Would you like to start the Ollama service automatically? (y/n): " start_ollama
        if [[ "${start_ollama,,}" == "y" ]]; then
            echo "[INFO] Starting Ollama service..."
            if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                sudo systemctl start ollama || (ollama serve >/dev/null 2>&1 &)
            else
                ollama serve >/dev/null 2>&1 &
            fi
            sleep 5
        else
            echo "[ERROR] Ollama service must be running to query models."
            exit 1
        fi
    fi

    # 2. ΑΥΤΟΜΑΤΟΠΟΙΗΣΗ: Έλεγχος αν είναι προσβάσιμο από το Docker (IP 172.17.0.1)
    if ! curl -s --connect-timeout 2 http://172.17.0.1:11434 >/dev/null 2>&1; then
        echo "[WARNING] Ollama is running but restricted to localhost. Automating network exposure for Docker..."
        
        # Αυτόματη δημιουργία του systemd override χωρίς χειροκίνητο edit
        sudo mkdir -p /etc/systemd/system/ollama.service.d
        echo -e "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0\"" | sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null
        
        echo "[INFO] Reloading systemd and restarting Ollama..."
        sudo systemctl daemon-reload
        sudo systemctl restart ollama
        sleep 4
        
        # Τελική επιβεβαίωση μετά την αυτόματη αλλαγή
        if ! curl -s --connect-timeout 2 http://172.17.0.1:11434 >/dev/null 2>&1; then
            echo "[ERROR] Automatic configuration failed. Docker still cannot reach Ollama."
            exit 1
        fi
        echo "[SUCCESS] Ollama is now automatically configured and accessible by Docker."
    fi
}

get_mdl() {
    echo "[INFO] Ensuring required AI models are downloaded..."
    ollama pull deepseek-r1:8b || exit 1
    ollama pull nomic-embed-text || exit 1
}

chk_doc() {
    echo "[INFO] Checking Docker installation..."
    if ! command -v docker >/dev/null 2>&1; then
        echo "[WARNING] Docker is not installed."
        read -p "Would you like to install Docker automatically? (y/n): " install_docker
        if [[ "${install_docker,,}" == "y" ]]; then
            echo "[INFO] Installing Docker via official script..."
            curl -fsSL https://get.docker.com | sudo sh
            echo "[SUCCESS] Docker installation triggered. Please ensure the daemon is running and re-run."
            exit 1
        else
            echo "[ERROR] Docker is required to run this application."
            exit 1
        fi
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "[WARNING] Docker daemon is closed or unresponsive."
        read -p "Would you like to start Docker daemon automatically? (y/n): " start_docker
        if [[ "${start_docker,,}" == "y" ]]; then
            echo "[INFO] Launching Docker daemon..."
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl start docker
            else
                sudo service docker start
            fi
            echo "[INFO] Waiting for Docker daemon to initialize..."
            sleep 20
            if ! docker info >/dev/null 2>&1; then
                echo "[ERROR] Docker daemon is still unresponsive."
                exit 1
            fi
        else
            echo "[ERROR] Docker daemon must be running."
            exit 1
        fi
    fi
}

chk_compose() {
    echo "[INFO] Checking Docker Compose (v2) installation..."
    if ! docker compose version >/dev/null 2>&1; then
        echo "[WARNING] Modern 'docker compose' (v2 plugin) was not found."
        read -p "Would you like to install Docker Compose v2 automatically? (y/n): " install_compose
        if [[ "${install_compose,,}" == "y" ]]; then
            echo "[INFO] Downloading and installing Docker Compose v2 plugin..."
            sudo mkdir -p /usr/libexec/docker/cli-plugins
            sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose
            sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
            
            if docker compose version >/dev/null 2>&1; then
                echo "[SUCCESS] Docker Compose v2 installed successfully."
            else
                echo "[ERROR] Docker Compose v2 installation failed."
                exit 1
            fi
        else
            echo "[ERROR] Modern 'docker compose' is required to run this application."
            exit 1
        fi
    fi
}

run_ingest() {
    echo "[INFO] Forwarding OLLAMA_HOST to Ingestion container..."
    if ! docker compose run --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-web python ingest.py; then
        echo "[ERROR] Ingestion failed. Operational abort."
        exit 1
    fi
}

run_terminal() {
    echo "[INFO] Starting Terminal Interface INSIDE Docker..."
    docker compose run --build --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-cli
}

run_webui() {
    echo "[INFO] Launching Gradio and Cloudflare Tunnel inside Docker..."
    OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" docker compose up --build -d rag-web rag-tunnel 

    echo "[INFO] Waiting for Cloudflare to generate public link..."
    sleep 10

    echo
    echo "==================================================="
    echo
    echo "Local URL:  http://localhost:7860"
    echo
    PUBLIC_URL=$(docker logs rag_cloudflare_tunnel 2>&1 | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | head -n 1)
    echo "Public Shareable URL: $PUBLIC_URL"
    echo
    echo "==================================================="
    echo "         Press any key to stop all processes"
    echo "==================================================="
    echo

    if command -v xdg-open > /dev/null; then
        xdg-open http://localhost:7860 &>/dev/null || true
    fi

    read -n 1 -s -r
    echo
    echo "[INFO] Stopping and removing containers..."
    docker compose down
}

menu_interface() {
    echo
    echo "==================================================="
    echo "                 Choose Interface"
    echo "==================================================="
    echo "[1] Stay in Terminal (Run chat.py INSIDE Docker)"
    echo "[2] Launch Web UI (Run Gradio INSIDE Docker)"
    echo
    read -p "Enter your choice (1 or 2): " choice

    if [ "$choice" == "1" ]; then
        run_terminal || exit 1
    elif [ "$choice" == "2" ]; then
        run_webui || exit 1
    else
        echo "[WARNING] Invalid choice. Exiting..."
        exit 1
    fi
}

# --- ΚΥΡΙΑ ΡΟΗ ΕΚΤΕΛΕΣΗΣ (NATIVE LINUX) ---
chk_ol && \
chk_svc && \
get_mdl && \
chk_doc && \
chk_compose && \
run_ingest && \
menu_interface

echo "Exiting program..."
echo
exit 0