# RAG Astro-Assistant

A Retrieval-Augmented Generation (RAG) system designed for analyzing and querying astronomy/astrophysics research papers. It utilizes **DeepSeek-R1 (7b/8b/14b/32b)** for generation and **nomic-embed-text** for embeddings via Ollama.

## Features
* **Zero-Footprint Docker Architecture:** Python dependencies are isolated within containers. It does not leave hidden cache files or disk clutter after removing the Docker images.
* **Multi-Platform Automation:** 
  * `launch.sh` for Native Linux.
  * `launch.bat` for Windows (CMD/PowerShell).
* **Native GPU Acceleration:** Offloads heavy AI computations to the native Ollama instance (Windows or Linux) to leverage direct GPU acceleration (AMD/NVIDIA) with zero performance loss.
* **Dual Interface:** Choose between a Terminal CLI (`chat.py`) or a Gradio Web UI (`gradio_app.py`).
* **Cloudflare Tunnel Integration:** Automatically generates a secure, public shareable link for remote access to the Web UI.

---

## System Requirements
* **Operating System:** Windows 10/11, Arch Linux, or Ubuntu/Debian.
* **Hardware Requirements:**
  * **RAM:** 8 GB minimum (16 GB recommended).
  * **GPU:** Dedicated NVIDIA or AMD GPU with at least **6 GB VRAM (heavily recommended)**. CPU-only execution is supported but results in significantly slower generation speeds.
  * **Storage:** ~10 GB available disk space (SSD).

## How to Run
The repository includes a pre-ingested and indexed vector database (`chroma_db`). You do not need to add any papers to start querying the system immediately, but you are welcome to experiment by adding more.

### 1. Launch the Application
Run the automated launch script for your platform:

**Linux:**
```bash
chmod +x launch.sh
./launch.sh
```

**Windows 10/11:**
```cmd
launch.bat
```

### 2. Choose Model and Interface
1. Select a model that fits your GPU VRAM pool.
2. Select your preferred mode from the terminal menu:
   * **1 (Terminal CLI):** Direct command-line chatting inside the terminal.
   * **2 (Web UI):** Launches the Gradio interface at `http://localhost:7860` and generates a public shareable Cloudflare Tunnel URL.

### 3. Adding Custom Papers (Optional)
To expand the system's knowledge base:
1. Place your new PDF files inside the `papers` folder.
2. Run the launch script. The system will automatically detect, ingest, and append the new documents to the existing `chroma_db`.