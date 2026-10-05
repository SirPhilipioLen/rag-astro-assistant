import os
import pymupdf
import chromadb
from llama_index.core import VectorStoreIndex, StorageContext, Document, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.core.node_parser import SentenceSplitter

# 1. Configuration
OLLAMA_BASE_URL = "http://host.docker.internal:11434"
os.environ["OLLAMA_HOST"] = OLLAMA_BASE_URL

DB_PATH = "./data/chroma_db"
COLLECTION_NAME = "rag_corpus"
PAPERS_DIR = "./papers"

# 2. Embedding Model Setup
Settings.embed_model = OllamaEmbedding(
    model_name="nomic-embed-text", 
    base_url=OLLAMA_BASE_URL,
    ollama_additional_kwargs={"keep_alive": 0}  # Free VRAM after completion
)

def get_existing_files(collection):
    """Retrieve a set of already indexed filenames."""
    existing = set()
    if collection.count() > 0:
        results = collection.get(include=["metadatas"])
        for metadata in results.get("metadatas", []):
            if metadata and "file_name" in metadata:
                existing.add(metadata["file_name"])
    return existing

def run_ingestion():
    os.makedirs(PAPERS_DIR, exist_ok=True)

    # 3. Database Initialization
    chroma_client = chromadb.PersistentClient(path=DB_PATH)
    chroma_collection = chroma_client.get_or_create_collection(COLLECTION_NAME)

    existing_files = get_existing_files(chroma_collection)
    all_files = [f for f in os.listdir(PAPERS_DIR) if f.endswith('.pdf')]
    
    if not all_files:
        print(f"[INFO] Place PDF files in '{PAPERS_DIR}' and rerun.")
        return

    new_files = [f for f in all_files if f not in existing_files]

    if not new_files:
        print("[INFO] All files are already synced. No new documents found.")
        return

    print(f"Found {len(new_files)} new file(s) to process.")
    documents = []

    # 4. Document Extraction
    for fname in new_files:
        print(f"Processing: {fname}...")
        pdf_path = os.path.join(PAPERS_DIR, fname)
        
        try:
            doc = pymupdf.open(pdf_path)
            for page_num, page in enumerate(doc, start=1):
                text = page.get_text()
                if text.strip():
                    documents.append(
                        Document(
                            text=text, 
                            metadata={
                                "file_name": fname,
                                "page_label": str(page_num)
                            }
                        )
                    )
        except Exception as e:
            print(f"[ERROR] Failed to read {fname}: {e}")
            continue

    if not documents:
        print("[WARNING] No text extracted from the new files.")
        return

    # 5. Embedding and Indexing
    print(f"Creating embeddings for {len(documents)} pages. This may take a moment...")

    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    splitter = SentenceSplitter(chunk_size=512, chunk_overlap=50)

    VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context,
        transformations=[splitter],
        show_progress=True
    )

    print("✓ Sync completed successfully!")

if __name__ == "__main__":
    run_ingestion()