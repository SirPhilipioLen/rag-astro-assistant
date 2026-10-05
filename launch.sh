#!/bin/bash

export DOCKER_CLI_HINTS=false

echo "==================================================="
echo "            Starting RAG Astro-Assistant"
echo "==================================================="
echo

# Linux native variables
OLLAMA_HOST_LOCAL="http://localhost:11434"
CONTAINER_OLLAMA_HOST="http://172.17.0.1:11434"

# Functions

chk_ol() {
    if ! command -v ollama >/dev/null 2>&1; then
        echo "[WARNING] Ollama was not found."
        read -p "Would you like to install Ollama automatically? (y/n): " install_ollama
        if [[ "${install_ollama,,}" == "y" ]]; then
            echo "[INFO] Installing Ollama via official script..."
            curl -fsSL https://ollama.com/install.sh | sh || exit 1
            echo "[SUCCESS] Ollama installed successfully."
        else
            echo "[ERROR] Ollama is required."
            exit 1
        fi
    fi
}

chk_doc() {
    echo "[INFO] Checking Docker installation..."
    if ! command -v docker >/dev/null 2>&1; then
        echo "[WARNING] Docker is not installed."
        read -p "Would you like to install Docker automatically? (y/n): " install_docker
        if [[ "${install_docker,,}" == "y" ]]; then
            echo "[INFO] Installing Docker..."
            if command -v pacman >/dev/null 2>&1; then
                sudo pacman -S --noconfirm --overwrite '*' docker || exit 1
            elif command -v apt-get >/dev/null 2>&1; then
                curl -fsSL https://get.docker.com | sudo sh || exit 1
            else
                echo "[ERROR] Unsupported package manager. Install Docker manually."
                exit 1
            fi
            echo "[SUCCESS] Docker installed."
            if ! groups $USER | grep -q "\bdocker\b"; then
                sudo usermod -aG docker $USER
                echo "[INFO] Added $USER to the docker group. You may need to logout and login."
            fi
        else
            echo "[ERROR] Docker is required."
            exit 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "[WARNING] Docker daemon is closed or unresponsive."
        read -p "Would you like to start the Docker service automatically? (y/n): " start_docker
        if [[ "${start_docker,,}" == "y" ]]; then
            echo "[INFO] Launching Docker daemon..."
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl start docker
            else
                sudo service docker start
            fi
            echo "[INFO] Waiting for Docker to initialize..."
            sleep 5
            if ! docker info >/dev/null 2>&1; then
                echo "[ERROR] Docker daemon is still unresponsive. (Try running 'newgrp docker' or restart terminal)"
                exit 1
            fi
        else
            echo "[ERROR] Docker daemon must be running."
            exit 1
        fi
    fi
}

chk_svc() {
    echo "[INFO] Checking if Ollama background service is active..."
    if ! curl -s "${OLLAMA_HOST_LOCAL}" >/dev/null 2>&1; then
        echo "[WARNING] Ollama service is not running."
        read -p "Would you like to start the Ollama service automatically? (y/n): " start_ollama
        if [[ "${start_ollama,,}" == "y" ]]; then
            echo "[INFO] Starting Ollama service in background..."
            if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled ollama >/dev/null 2>&1; then
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
}

select_model() {
    echo
    echo "==================================================="
    echo "        Select Generative Model (Reasoning)"
    echo "==================================================="
    echo "Choose the model size based on your GPU VRAM:"
    echo "[1] deepseek-r1:7b  (Requires ~5GB VRAM) - DEFAULT"
    echo "[2] deepseek-r1:8b  (Requires ~6GB VRAM)"
    echo "[3] deepseek-r1:14b (Requires ~10GB VRAM)"
    echo "[4] deepseek-r1:32b (Requires ~20GB VRAM)"
    echo
    read -p "Enter your choice (1-4) [Press Enter for 1]: " mdl_choice

    if [ "$mdl_choice" == "2" ]; then
        LLM_MODEL="deepseek-r1:8b"
    elif [ "$mdl_choice" == "3" ]; then
        LLM_MODEL="deepseek-r1:14b"
    elif [ "$mdl_choice" == "4" ]; then
        LLM_MODEL="deepseek-r1:32b"
    else
        LLM_MODEL="deepseek-r1:7b"
    fi

    echo "[INFO] Selected Model: $LLM_MODEL"

    # Export to .env for Docker Compose
    echo "OLLAMA_HOST=${CONTAINER_OLLAMA_HOST}" > .env
    echo "LLM_MODEL=${LLM_MODEL}" >> .env
}

get_mdl() {
    echo "[INFO] Ensuring required AI models are available..."

    if ! ollama list | grep -q "${LLM_MODEL}"; then
        echo "[INFO] Model ${LLM_MODEL} not found. Downloading..."
        ollama pull "${LLM_MODEL}" || exit 1
    fi

    if ! ollama list | grep -q "nomic-embed-text"; then
        echo "[INFO] Model nomic-embed-text not found. Downloading..."
        ollama pull nomic-embed-text || exit 1
    fi

    echo "[SUCCESS] All required models are ready."
}

run_ingest() {
    echo "[INFO] Checking vector database status..."
    if ! docker compose -f docker/docker-compose.yml --env-file .env run --rm rag-web python src/ingest.py; then
        echo "[ERROR] Ingestion failed. Operational abort."
        exit 1
    fi
}

run_terminal() {
    echo "[INFO] Starting Terminal Interface inside Docker..."
    docker compose -f docker/docker-compose.yml --env-file .env run --rm rag-cli
}

run_webui() {
    echo "[INFO] Launching Gradio and Cloudflare Tunnel inside Docker..."
    docker compose -f docker/docker-compose.yml --env-file .env up -d rag-web rag-tunnel 

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
    echo "        Press any key to stop all processes"
    echo "==================================================="
    echo

    if command -v xdg-open > /dev/null; then
        xdg-open http://localhost:7860 &>/dev/null || true
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

# Main flow
chk_ol && \
chk_doc && \
chk_svc && \
select_model && \
get_mdl && \
run_ingest && \
menu_interface

echo "Exiting program..."
echo
exit 0