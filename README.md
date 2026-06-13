# RAG Astro-Assistant

A Retrieval-Augmented Generation (RAG) system designed for analyzing and querying astronomy/astrophysics research papers. It utilizes **DeepSeek-R1 (8B)** for generation and **nomic-embed-text** for embeddings via Ollama.

## Features
* **Zero-Footprint Docker Architecture:** Python dependencies are isolated within containers. It does not leave hidden cache files or disk clutter after removing the Docker images.
* **Multi-Platform Automation:** 
  * `launch.sh` for Native Linux and WSL.
  * `launch.bat` for Windows.
* **Native GPU Acceleration:** Offloads heavy AI computations to the native Ollama instance (Windows or Linux) to leverage direct GPU acceleration (AMD/NVIDIA) with zero performance loss.
* **Dual Interface:** Choose between a Terminal CLI (`chat.py`) or a Gradio Web UI (`gradio_app.py`).
* **Cloudflare Tunnel Integration:** Automatically generates a secure, public shareable link for remote access to the Web UI.

---

## System Requirements
* **Operating System:** Windows 10/11 (Native or WSL2), Arch Linux, or Ubuntu/Debian.
* **Hardware Requirements:**
  * **RAM:** 8 GB minimum (16 GB recommended).
  * **GPU:** Dedicated NVIDIA or AMD GPU with at least **6 GB VRAM (heavily recommended)**. CPU-only execution is supported but results in significantly slower generation speeds.
  * **Storage:** ~10 GB available disk space (SSD).