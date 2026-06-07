FROM python:3.12-slim

WORKDIR /app

# Εγκατάσταση απαραίτητων πακέτων συστήματος
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Αναβάθμιση pip
RUN pip install --no-cache-dir --upgrade pip

# Εγκατάσταση βιβλιοθηκών Python
RUN pip install --no-cache-dir \
    gradio==6.15.0 \
    ollama \
    llama-index \
    llama-index-llms-ollama \
    llama-index-embeddings-ollama \
    chromadb \
    pymupdf \
    llama-index-vector-stores-chroma \
    rich

# Environment variables
ENV PYTHONUNBUFFERED=1

# Αντιγραφή του κώδικα (Στο τέλος για σωστό Docker caching)
COPY gradio_app.py .
COPY chat.py .

EXPOSE 7860

CMD ["python", "gradio_app.py"]