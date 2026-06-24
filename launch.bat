@echo off
setlocal enabledelayedexpansion
set DOCKER_CLI_HINTS=false

echo ===================================================
echo            Starting RAG Astro-Assistant
echo ===================================================
echo.

REM Main flow
call :chk_ol && ^
call :chk_doc && ^
call :chk_svc && ^
call :get_mdl && ^
call :run_ingest && ^
call :menu_interface

echo Exiting program...
echo.
pause
exit /b 0


REM Functions

:chk_ol
where ollama >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Ollama was not found.
    set /p "install_ollama=Would you like to install Ollama automatically? (y/n): "
    if /i "!install_ollama!"=="y" (
        echo [INFO] Installing Ollama via Winget...
        winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
        echo [SUCCESS] Ollama installed successfully.
    ) else (
        echo [ERROR] Ollama is required.
        exit /b 1
    )
)
exit /b 0

:chk_svc
echo [INFO] Checking if Ollama background service is active...
curl -s http://localhost:11434 >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Ollama service is not running.
    set /p "start_ollama=Would you like to start the Ollama service automatically? (y/n): "
    if /i "!start_ollama!"=="y" (
        echo [INFO] Starting Ollama service in background...
        
        rem Start daemon silently
        powershell -Command "$env:OLLAMA_HOST='0.0.0.0'; Start-Process -FilePath 'ollama.exe' -ArgumentList 'serve' -WindowStyle Hidden"
        
        timeout /t 5 /nobreak >nul
    ) else (
        echo [ERROR] Ollama service must be running to query models.
        exit /b 1
    )
)
exit /b 0

:get_mdl
echo [INFO] Ensuring required AI models are available...

rem Check models
ollama list | findstr /C:"deepseek-r1:8b" >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Model deepseek-r1:8b not found. Downloading...
    ollama pull deepseek-r1:8b || exit /b 1
)

ollama list | findstr /C:"nomic-embed-text" >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Model nomic-embed-text not found. Downloading...
    ollama pull nomic-embed-text || exit /b 1
)

echo [SUCCESS] All required models are ready.
exit /b 0

:chk_doc
echo [INFO] Checking Docker installation...
docker --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Docker is not installed.
    set /p "install_docker=Would you like to install Docker Desktop automatically? (y/n): "
    if /i "!install_docker!"=="y" (
        echo [INFO] Installing Docker Desktop via Winget...
        winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
        echo [SUCCESS] Docker installation triggered. Please start Docker Desktop and re-run.
        exit /b 1
    ) else (
        echo [ERROR] Docker is required to run this application.
        exit /b 1
    )
)
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARNING] Docker Desktop is closed.
    set /p "start_docker=Would you like to start Docker Desktop automatically? (y/n): "
    if /i "!start_docker!"=="y" (
        echo [INFO] Launching Docker Desktop...
        start "" "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        echo [INFO] Waiting for Docker daemon to initialize...
        timeout /t 20 /nobreak >nul
        docker info >nul 2>&1
        if !errorlevel! neq 0 (
            echo [ERROR] Docker daemon is still unresponsive.
            exit /b 1
        )
    ) else (
        echo [ERROR] Docker daemon must be running.
        exit /b 1
    )
)
exit /b 0

:run_ingest
echo [INFO] Setting environment variables...
set OLLAMA_HOST=http://host.docker.internal:11434
echo [INFO] Checking vector database status...
docker compose -f docker/docker-compose.yml run --rm rag-web python src/ingest.py
if !errorlevel! neq 0 (
    echo [ERROR] Ingestion failed. Operational abort.
    exit /b 1
)
exit /b 0

:run_terminal
echo [INFO] Starting Terminal Interface inside Docker...
docker compose -f docker/docker-compose.yml run --rm rag-cli
exit /b 0

:run_webui
echo [INFO] Launching Gradio and Cloudflare Tunnel inside Docker...
docker compose -f docker/docker-compose.yml up -d rag-web rag-tunnel 

echo [INFO] Waiting for Cloudflare to generate public link...
timeout /t 10 /nobreak >nul

echo.
echo ===================================================
echo.
echo Local URL:  http://localhost:7860
echo.
for /f "tokens=4" %%a in ('docker logs rag_cloudflare_tunnel 2^>^&1 ^| findstr "https" ^| findstr "trycloudflare.com"') do set "PUBLIC_URL=%%a"
echo Public Shareable URL: %PUBLIC_URL%
echo.
echo ===================================================
echo         Press any key to stop all processes
echo ===================================================
echo.

start http://localhost:7860
pause >nul

echo [INFO] Stopping and removing containers...
docker compose -f docker/docker-compose.yml down
exit /b 0

:menu_interface
echo.
echo ===================================================
echo                 Choose Interface
echo ===================================================
echo [1] Stay in Terminal
echo [2] Launch Web UI
echo.
set /p "choice=Enter your choice (1 or 2): "

if "%choice%"=="1" (
    call :run_terminal || exit /b 1
) else if "%choice%"=="2" (
    call :run_webui || exit /b 1
) else (
    echo [WARNING] Invalid choice. Exiting...
    exit /b 1
)
exit /b 0