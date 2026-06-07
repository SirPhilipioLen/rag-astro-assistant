#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "==================================================="
echo "           Starting RAG Astro-Assistant            " 
echo "==================================================="
echo

# 1. Έλεγχος Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERROR] Docker is not installed.${NC}"
    exit 1
fi

# 2. Ανίχνευση Περιβάλλοντος
if grep -qi microsoft /proc/version; then
    echo -e "${YELLOW}⚠️  WSL2 detected - Using Windows Host Ollama via Docker DNS.${NC}"
    PROFILE="wsl"
    export OLLAMA_HOST="http://host.docker.internal:11434"
else
    echo -e "${GREEN}🐧 Native Linux detected - Using Docker Ollama.${NC}"
    PROFILE="linux"
    export OLLAMA_HOST="http://ollama-service:11434"
fi

# 3. Εκκίνηση Βασικών Containers (Gradio / Ollama)
echo -e "${GREEN}[INFO] Launching Docker background services...${NC}"
docker compose --profile $PROFILE up -d

# 4. Έλεγχος αν το Ollama ανταποκρίνεται
echo -e "${GREEN}[INFO] Waiting for Ollama service...${NC}"
if [ "$PROFILE" == "wsl" ]; then
    until cmd.exe /c "ollama list" > /dev/null 2>&1; do echo -n "."; sleep 2; done
else
    until docker exec ollama_rag curl -s http://localhost:11434 > /dev/null 2>&1; do echo -n "."; sleep 2; done
fi
echo -e "\n${GREEN}[SUCCESS] Ollama is active!${NC}"

# 5. Κατέβασμα Μοντέλων
echo -e "${GREEN}[INFO] Checking AI models...${NC}"
if [ "$PROFILE" == "wsl" ]; then
    cmd.exe /c "ollama pull deepseek-r1:8b"
    cmd.exe /c "ollama pull nomic-embed-text"
else
    docker exec -it ollama_rag ollama pull deepseek-r1:8b
    docker exec -it ollama_rag ollama pull nomic-embed-text
fi

# 6. Μενού Επιλογής UI
echo
echo "==================================================="
echo "                  CHOOSE INTERFACE                 "
echo "==================================================="
echo "[1] Stay in Terminal (Run inside Docker Container)"
echo "[2] Launch Web UI (Open Gradio in Browser)"
echo
read -p "Enter your choice (1 or 2): " choice

if [ "$choice" == "1" ]; then
    echo -e "\n[INFO] Launching Terminal App inside Docker..."
    docker compose run --rm -it rag-terminal

elif [ "$choice" == "2" ]; then
    echo -e "\n[INFO] Opening browser to Gradio Web UI..."
    sleep 2
    if grep -qi microsoft /proc/version; then
        cmd.exe /c "start http://localhost:7860"
    else
        xdg-open http://localhost:7860 || echo "Please open http://localhost:7860 manually."
    fi
    echo -e "${GREEN}🌐 Application is running at http://localhost:7860${NC}"

else
    echo -e "${YELLOW}[INFO] Defaulting to Terminal App...${NC}"
    docker compose run --rm -it rag-terminal
fi