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
    # Auto-create folder if it doesn't exist
    os.makedirs(PAPERS_DIR, exist_ok=True)

    chroma_client = chromadb.PersistentClient(path=DB_PATH)
    chroma_collection = chroma_client.get_or_create_collection(COLLECTION_NAME)

    # Find files that have already been indexed
    existing_files = set()
    if chroma_collection.count() > 0:
        # Get the metadata of existing documents to see file_names
        results = chroma_collection.get(include=["metadatas"])
        for metadata in results.get("metadatas", []):
            if metadata and "file_name" in metadata:
                existing_files.add(metadata["file_name"])

    # Check if there are PDF files to process
    all_files = [f for f in os.listdir(PAPERS_DIR) if f.endswith('.pdf')]
    
    if not all_files:
        print(f"[INFO] Place PDF files in the '{PAPERS_DIR}' folder and rerun the script.")
        return

    # Filter: Keep only new files
    new_files = [f for f in all_files if f not in existing_files]

    if not new_files:
        print("[INFO] All files are already synced. No new documents found.")
        return

    print(f"Found {len(new_files)} new files to process.")
    documents = []

    for fname in new_files:
        print(f"Processing: {fname}...")
        pdf_path = os.path.join(PAPERS_DIR, fname)
        
        try:
            doc = pymupdf.open(pdf_path)
            # Extract per page to keep page number in metadata
            for page_num, page in enumerate(doc, start=1):
                text = page.get_text()
                if text.strip():  # Skip empty pages
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
            print(f"[ERROR] Failed to read file {fname}: {e}")
            continue

    if not documents:
        print("[WARNING] No text was extracted from the new files.")
        return

    print(f"Creating embeddings for {len(documents)} pages...")

    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    splitter = SentenceSplitter(chunk_size=512, chunk_overlap=50)

    # Add new documents to the existing index
    VectorStoreIndex.from_documents(
        documents,
        storage_context=storage_context,
        transformations=[splitter],
        show_progress=True
    )

    print("✓ Sync completed successfully!")

if __name__ == "__main__":
    run_ingestion()