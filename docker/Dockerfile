FROM python:3.12-slim

WORKDIR /app

# Environment variables (αποφυγή αρχείων .pyc και άμεσο output των logs)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Εγκατάσταση ca-certificates, αναβάθμιση pip και βιβλιοθηκών σε ΕΝΑ layer με χρήση cache mount
RUN apt-get update && apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --upgrade pip && \
    pip install \
    gradio==6.15.0 \
    ollama \
    llama-index \
    llama-index-llms-ollama \
    llama-index-embeddings-ollama \
    chromadb \
    pymupdf \
    llama-index-vector-stores-chroma \
    rich

COPY src/ ./src/

EXPOSE 7860

CMD ["python", "src/gradio_app.py"]