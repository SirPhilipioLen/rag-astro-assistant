# RAG Astro-Assistant

A Retrieval-Augmented Generation (RAG) system designed for analyzing and querying astronomy/astrophysics research papers. It utilizes **DeepSeek-R1 (8B)** for generation and **nomic-embed-text** for embeddings via Ollama.

## Features
* **Zero-Footprint Docker Architecture:** Python dependencies are isolated within containers. It does not leave hidden cache files or disk clutter after removing the Docker images.
* **Multi-Platform Automation:** * `launch.sh` for Native Linux and WSL (Bash).
  * `launch.bat` for Native Windows (Batch).
* **Native GPU Acceleration:** Offloads heavy AI computations to the native Ollama instance (Windows or Linux) to leverage direct GPU acceleration (AMD/NVIDIA) with zero performance loss.
* **Dual Interface:** Choose between a Terminal CLI (`chat.py`) or a Gradio Web UI (`gradio_app.py`).
* **Cloudflare Tunnel Integration:** Automatically generates a secure, public shareable link for remote access to the Web UI.

---

## System Requirements
* **Operating System:** Windows 10/11 (Native or WSL2), Arch Linux, or Ubuntu/Debian.
* **Hardware Requirements:**
  * **GPU:** Dedicated NVIDIA or AMD GPU with at least **8 GB VRAM** (required for full GPU acceleration of the 8B model).
  * **Storage:** ~8 GB available disk space.

---

## Project Structure
├── papers/                  # Place your PDF papers here (User interaction)
├── launch.sh                # Main entry point for Linux / WSL
├── launch.bat               # Main entry point for Windows
├── src/                     # All Python source code
│   ├── chat.py
│   ├── gradio_app.py
│   └── ingest.py
└── docker/                  # All Docker configuration files
    ├── Dockerfile
    └── docker-compose.yml