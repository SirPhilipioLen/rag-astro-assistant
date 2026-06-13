#!/bin/bash

export DOCKER_CLI_HINTS=false

echo "==================================================="
echo "           Starting RAG Astro-Assistant"
echo "==================================================="
echo

# Environment detection
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
fi

if [ "$IS_WSL" = true ]; then
    echo "[INFO] Environment detected: WSL (Windows Subsystem for Linux)"
    # Resolve Windows IP
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

# Functions

chk_ol() {
    if ! command -v ollama >/dev/null 2>&1 && ! cmd.exe /c "where ollama" >/dev/null 2>&1; then
        echo "[WARNING] Ollama was not found in the environment."
        
        if [ "$IS_WSL" = true ]; then
            read -p "Would you like to install Ollama via winget on Windows? (y/n): " install_ollama
            if [[ "${install_ollama,,}" == "y" ]]; then
                echo "[INFO] Installing Ollama via Windows Package Manager (winget)..."
                
                # Silent installation with automatic agreement acceptance
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
            read -p "Would you like to install Ollama automatically (y/n): " install_ollama
            if [[ "${install_ollama,,}" == "y" ]]; then
                echo "[INFO] Installing Ollama via official universal script..."
                
                # Fail fast if curl or script execution fails
                curl -fsSL https://ollama.com/install.sh | sh || exit 1
                
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
    
    # Fast fail with 3s timeout
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
            
            # Wait for service
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

    # Windows WSL specific OLLAMA_HOST routing
    if [ "$IS_WSL" = true ]; then
        # Bind to 0.0.0.0 if not already set
        CURRENT_WIN_HOST=$(powershell.exe -Command "[Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')" | tr -d '\r')
        
        if [ "$CURRENT_WIN_HOST" != "0.0.0.0" ]; then
            echo "[WARNING] Windows Ollama is restricted to localhost. Automating 0.0.0.0 binding..."
            
            # Set env var
            powershell.exe -Command "[Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')"
            
            # Stop process
            powershell.exe -Command "Stop-Process -Name 'ollama' -Force -ErrorAction SilentlyContinue"
            
            # Restart app
            powershell.exe -Command "Start-Process -FilePath 'ollama app.exe'"
            
            echo "[SUCCESS] Windows Ollama configured to 0.0.0.0 and restarted."
            sleep 3
        fi
    fi
}

get_mdl() {
    echo "[INFO] Ensuring required AI models are available..."
    
    # Check if model exists before pulling
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
        read -p "Would you like to install Docker automatically? (y/n): " install_docker
        
        if [[ "${install_docker,,}" == "y" ]]; then
            echo "[INFO] Detecting package manager and installing Docker..."
            if command -v pacman >/dev/null 2>&1; then
                # Arch Linux (Native & WSL) - Force overwrite to handle orphan binary conflicts
                sudo pacman -S --noconfirm --overwrite '*' docker || exit 1
            elif command -v apt-get >/dev/null 2>&1; then
                # Debian/Ubuntu fallback
                curl -fsSL https://get.docker.com | sudo sh || exit 1
            else
                echo "[ERROR] Unsupported package manager. Please install Docker manually."
                exit 1
            fi
            
            echo "[SUCCESS] Docker installed successfully."
            hash -r # Refresh bash command paths to recognize 'docker' binary immediately
            
            # Ensure user belongs to the docker group
            if ! groups $USER | grep -q "\bdocker\b"; then
                sudo usermod -aG docker $USER
                echo "[INFO] Added $USER to the docker group."
            fi
        else
            echo "[ERROR] Docker is required to run this application."
            exit 1
        fi
    fi

    # Check and automatically start the daemon if it is unresponsive
    if ! docker info >/dev/null 2>&1; then
        echo "[WARNING] Docker daemon is closed or unresponsive."
        echo "[INFO] Launching Docker daemon..."
        
        if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
            sudo systemctl start docker
        else
            sudo service docker start
        fi
        
        echo "[INFO] Waiting for Docker daemon to initialize..."
        sleep 5
        
        # Guard clause for fresh installations requiring a group session refresh
        if ! docker info >/dev/null 2>&1; then
            echo "[WARNING] Docker daemon is running, but terminal session lacks group permissions."
            echo "[INFO] Please run 'newgrp docker' or restart your terminal, then re-run ./launch.sh"
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
            echo "[INFO] Detecting package manager and installing Docker Compose..."
            if command -v pacman >/dev/null 2>&1; then
                sudo pacman -S --noconfirm docker-compose || exit 1
            elif command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y docker-compose-plugin || exit 1
            else
                echo "[ERROR] Unsupported package manager. Please install 'docker-compose' manually."
                exit 1
            fi
            
            if docker compose version >/dev/null 2>&1; then
                echo "[SUCCESS] Docker Compose v2 installed successfully."
            else
                echo "[ERROR] Installation completed but 'docker compose' is still unavailable."
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
    if ! docker compose -f docker/docker-compose.yml run --build --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-web python src/ingest.py; then
        echo "[ERROR] Ingestion failed. Operational abort."
        exit 1
    fi
}

run_terminal() {
    echo "[INFO] Starting Terminal Interface inside Docker..."
    docker compose -f docker/docker-compose.yml run --rm -e OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" rag-cli
}

run_webui() {
    echo "[INFO] Launching Gradio and Cloudflare Tunnel inside Docker..."
    OLLAMA_HOST="$CONTAINER_OLLAMA_HOST" docker compose -f docker/docker-compose.yml up -d rag-web rag-tunnel 

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

    # Open browser
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
    docker compose -f docker/docker-compose.yml down
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

# Main execution flow
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