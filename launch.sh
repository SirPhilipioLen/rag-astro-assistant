#!/bin/bash

export DOCKER_CLI_HINTS=false

echo "==================================================="
echo "           Starting RAG Astro-Assistant"
echo "==================================================="
echo

# --- ΑΥΤΟΜΑΤΟΣ ΕΝΤΟΠΙΣΜΟΣ ΠΕΡΙΒΑΛΛΟΝΤΟΣ (WSL vs NATIVE LINUX) ---
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi

if [ "$IS_WSL" = true ]; then
    echo "[INFO] Environment detected: WSL (Windows Subsystem for Linux)"
    # Δυναμική εύρεση της IP των Windows
    WSL_GATEWAY=$(ip route | grep default | awk '{print $3}')
    export OLLAMA_HOST="http://$WSL_GATEWAY:11434"
    export CONTAINER_OLLAMA_HOST="http://$WSL_GATEWAY:11434"
    
    if command -v ollama.exe >/dev/null 2>&1; then
        OLLAMA_CMD="ollama.exe"
    else
        OLLAMA_CMD="ollama"
    fi
else
    echo "[INFO] Environment detected: Native Linux"
    export OLLAMA_HOST="http://localhost:11434"
    export CONTAINER_OLLAMA_HOST="http://172.17.0.1:11434"
    OLLAMA_CMD="ollama"
fi

# === ΣΥΝΑΡΤΗΣΕΙΣ ===

chk_ol() {
    if ! command -v ollama >/dev/null 2>&1 && ! cmd.exe /c "where ollama" >/dev/null 2>&1; then
        echo "[WARNING] Ollama was not found on Windows."
        
        if [ "$IS_WSL" = true ]; then
            read -p "Would you like to install Ollama via winget? (y/n): " install_ollama
            if [[ "${install_ollama,,}" == "y" ]]; then
                echo "[INFO] Installing Ollama via Windows Package Manager (winget)..."
                
                # Αυτόματη εγκατάσταση χωρίς παράθυρα και με αυτόματη αποδοχή όρων
                powershell.exe -Command "winget install Ollama.Ollama --silent --accept-source-agreements --accept-package-agreements"
                
                echo "[SUCCESS] Installation trigger complete."
                echo "[INFO] Please ensure Ollama is running in your Windows system tray and re-run ./launch.sh"
                exit 0
            else
                echo "[ERROR] Ollama is required to run this application."
                exit 1
            fi
        else
            # Native Linux logic
            read -p "Would you like to install Ollama automatically on Linux? (y/n): " install_ollama
            if [[ "${install_ollama,,}" == "y" ]]; then
                echo "[INFO] Installing Ollama..."
                curl -fsSL https://ollama.com/install.sh | sh
                echo "[SUCCESS] Ollama installed successfully."
            else
                echo "[ERROR] Ollama is required."
                exit 1
            fi
        fi
    fi
}
chk_svc() {
    echo "[INFO] Checking if Ollama background service is active..."
    
    # ΔΙΟΡΘΩΣΗ: Προσθήκη --connect-timeout για να αποτυγχάνει ακαριαία (σε 3s) αν είναι κλειστό
    if ! curl -s --connect-timeout 3 --max-time 5 "$OLLAMA_HOST" >/dev/null 2>&1; then
        echo "[WARNING] Ollama service is not running."
        read -p "Would you like to start the Ollama service automatically? (y/n): " start_ollama
        if [[ "${start_ollama,,}" == "y" ]]; then
            echo "[INFO] Starting Ollama service..."
            if [ "$IS_WSL" = true ]; then
                powershell.exe -Command "$env:OLLAMA_HOST='0.0.0.0'; Start-Process -FilePath 'ollama.exe' -ArgumentList 'serve' -WindowStyle Hidden" >/dev/null 2>&1
            else
                if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                    sudo systemctl start ollama || (ollama serve >/dev/null 2>&1 &)
                else
                    ollama serve >/dev/null 2>&1 &
                fi
            fi
            
            echo "[INFO] Waiting for Ollama service to initialize..."
            
            # Δυναμικό loop ελέγχου διαθεσιμότητας
            local counter=0
            while [ $counter -lt 15 ]; do
                if curl -s --connect-timeout 2 "$OLLAMA_HOST" >/dev/null 2>&1; then
                    echo ""
                    echo "[SUCCESS] Ollama service is ready!"
                    break
                fi
                sleep 2
                echo -n "."
                counter=$((counter + 1))
            done
            
            if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" >/dev/null 2>&1; then
                echo ""
                echo "[ERROR] Ollama service failed to initialize."
                exit 1
            fi
        else
            echo "[ERROR] Ollama service must be running to query models."
            exit 1
        fi
    fi

    # Βελτιστοποίηση AMD GPU και Docker Routing (Μόνο για Native Linux)
    # Προσθήκη αυτοματοποίησης Windows μέσα στη chk_svc() αν IS_WSL = true
    if [ "$IS_WSL" = true ]; then
        # Έλεγχος αν η μεταβλητή OLLAMA_HOST είναι ήδη 0.0.0.0 στα Windows
        CURRENT_WIN_HOST=$(powershell.exe -Command "[Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')" | tr -d '\r')
        
        if [ "$CURRENT_WIN_HOST" != "0.0.0.0" ]; then
            echo "[WARNING] Windows Ollama is restricted to localhost. Automating 0.0.0.0 binding..."
            
            # 1. Ορισμός της μεταβλητής περιβάλλοντος στα Windows
            powershell.exe -Command "[Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')"
            
            # 2. Τερματισμός του τρέχοντος Ollama process στα Windows
            powershell.exe -Command "Stop-Process -Name 'ollama' -Force -ErrorAction SilentlyContinue"
            
            # 3. Επανεκκίνηση του Ollama App στα Windows για να διαβάσει τη νέα μεταβλητή
            powershell.exe -Command "Start-Process -FilePath 'ollama app.exe'"
            
            echo "[SUCCESS] Windows Ollama configured to 0.0.0.0 and restarted."
            sleep 3
        fi
    fi
}

get_mdl() {
    echo "[INFO] Ensuring required AI models are available..."
    
    # ΔΙΟΡΘΩΣΗ: Έλεγχος πριν το pull για αποφυγή offline crashes
    if ! $OLLAMA_CMD list | grep -q "deepseek-r1:8b"; then
        echo "[INFO] Model deepseek-r1:8b not found. Downloading..."
        $OLLAMA_CMD pull deepseek-r1:8b || exit 1
    fi

    if ! $OLLAMA_CMD list | grep -q "nomic-embed-text"; then
        echo "[INFO] Model nomic-embed-text not found. Downloading..."
        $OLLAMA_CMD pull nomic-embed-text || exit 1
    fi

    echo "[SUCCESS] All required models are ready."
}

chk_doc() {
    echo "[INFO] Checking Docker installation..."
    if ! command -v docker >/dev/null 2>&1; then
        echo "[WARNING] Docker is not installed."
        if [ "$IS_WSL" = true ]; then
            echo "[ERROR] Please install Docker Desktop on Windows and enable WSL integration in settings."
            exit 1
        else
            read -p "Would you like to install Docker automatically? (y/n): " install_docker
            if [[ "${install_docker,,}" == "y" ]]; then
                echo "[INFO] Installing Docker via official script..."
                curl -fsSL https://get.docker.com | sudo sh
                echo "[SUCCESS] Docker installed. Please ensure the daemon is running and re-run."
                exit 1
            else
                echo "[ERROR] Docker is required to run this application."
                exit 1
            fi
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "[WARNING] Docker daemon is closed or unresponsive."
        read -p "Would you like to start Docker daemon automatically? (y/n): " start_docker
        if [[ "${start_docker,,}" == "y" ]]; then
            echo "[INFO] Launching Docker daemon..."
            if [ "$IS_WSL" = true ]; then
                # Χρήση PowerShell για πλήρη αποδέσμευση της διεργασίας από το WSL tty
                powershell.exe -Command "Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'" >/dev/null 2>&1
            else
                if command -v systemctl >/dev/null 2>&1; then
                    sudo systemctl start docker
                else
                    sudo service docker start
                fi
            fi
            
            echo "[INFO] Waiting for Docker daemon to initialize..."
            
            # Δυναμικό loop ελέγχου ανά 2 δευτερόλεπτα
            local counter=0
            local max_wait=60 # 30 * 2 = 60 δευτερόλεπτα μέγιστη αναμονή
            while [ $counter -lt $max_wait ]; do
                if docker info >/dev/null 2>&1; then
                    echo ""
                    echo "[SUCCESS] Docker daemon is ready!"
                    return 0
                fi
                sleep 2
                echo -n "."
                counter=$((counter + 1))
            done
            
            echo ""
            echo "[ERROR] Docker daemon is still unresponsive after 60 seconds."
            exit 1
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
        if [ "$IS_WSL" = true ]; then
            echo "[ERROR] Modern 'docker compose' is required. Please update Docker Desktop."
            exit 1
        fi
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
    if ! docker compose run --build --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-web python ingest.py; then
        echo "[ERROR] Ingestion failed. Operational abort."
        exit 1
    fi
}

run_terminal() {
    echo "[INFO] Starting Terminal Interface inside Docker..."
    # Αφαιρέθηκε το --build για ταχύτητα
    docker compose run --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-cli
}

run_webui() {
    echo "[INFO] Launching Gradio and Cloudflare Tunnel inside Docker..."
    # Αφαιρέθηκε το --build για ταχύτητα
    OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" docker compose up -d rag-web rag-tunnel 

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

    # Άνοιγμα browser ανάλογα με το περιβάλλον
    if [ "$IS_WSL" = true ]; then
        cmd.exe /c start http://localhost:7860 2>/dev/null
    else
        if command -v xdg-open > /dev/null; then
            xdg-open http://localhost:7860 &>/dev/null || true
        fi
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
    echo "[1] Stay in Terminal"
    echo "[2] Launch Web UI"
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
# Να μείνει έτσι:
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