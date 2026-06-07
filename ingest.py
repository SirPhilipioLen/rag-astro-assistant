import os
import pymupdf
import chromadb
from llama_index.core import VectorStoreIndex, StorageContext, Document, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.core.node_parser import SentenceSplitter

# 1. Configuration
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://host.docker.internal:11434")
Settings.embed_model = OllamaEmbedding(model_name="nomic-embed-text", base_url=OLLAMA_HOST)

DB_PATH = "./chroma_db"
COLLECTION_NAME = "astro_rag_corpus"
PAPERS_DIR = "./papers"

def run_ingestion():
    chroma_client = chromadb.PersistentClient(path=DB_PATH)
    chroma_collection = chroma_client.get_or_create_collection(COLLECTION_NAME)

    # Έλεγχος αν υπάρχουν ήδη δεδομένα (Αποφυγή διπλού indexing)
    if chroma_collection.count() > 0:
        print("[INFO] Vector database already indexed. Skipping ingestion.")
        return

    # Έλεγχος ύπαρξης φακέλου (Αποφυγή crash)
    if not os.path.exists(PAPERS_DIR) or not any(f.endswith('.pdf') for f in os.listdir(PAPERS_DIR)):
        print(f"[ERROR] No PDFs found in '{PAPERS_DIR}'. Place your papers there first.")
        return

    print("Loading papers from ./papers/...")
    documents = []
    for fname in os.listdir(PAPERS_DIR):
        if fname.endswith(".pdf"):
            print(f"Loading {fname}...")
            pdf_path = os.path.join(PAPERS_DIR, fname)
            doc = pymupdf.open(pdf_path)
            text = "".join(page.get_text() for page in doc)
            documents.append(Document(text=text, metadata={"file_name": fname}))

    print(f"✓ Loaded {len(documents)} documents")
    print("Indexing...")

    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    splitter = SentenceSplitter(chunk_size=512, chunk_overlap=50)

    VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context,
        transformations=[splitter],
        show_progress=True
    )

    print("✓ Indexing complete! chroma_db is ready.")

if __name__ == "__main__":
    run_ingestion()