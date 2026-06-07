import os
import gradio as gr
import chromadb
from ollama import Client
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.vector_stores.chroma import ChromaVectorStore

# 1. Αυτόματος εντοπισμός περιβάλλοντος (Docker ή Windows Local)
if os.path.exists("/.dockerenv"):
    # Μέσα στο Docker: Κοιτάζει τα Windows μέσω της ειδικής DNS πύλης
    OLLAMA_BASE_URL = os.getenv("OLLAMA_HOST", "http://host.docker.internal:11434")
else:
    # Έξω από το Docker (Τοπικά): Κοιτάζει το localhost
    OLLAMA_BASE_URL = "http://127.0.0.1:11434"

print(f"[INFO] Connecting to Ollama at: {OLLAMA_BASE_URL}")

# 2. Αρχικοποίηση ΕΝΟΣ ενιαίου Client για όλο το script
ollama_client = Client(host=OLLAMA_BASE_URL)
embed_model = OllamaEmbedding(model_name="nomic-embed-text", base_url=OLLAMA_BASE_URL)
Settings.embed_model = embed_model

# 3. Φόρτωση Index από ChromaDB
chroma_client = chromadb.PersistentClient(path="./chroma_db")
chroma_collection = chroma_client.get_or_create_collection("astro_rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

# ΔΙΟΡΘΩΣΗ: Προσθήκη embed_model και μείωση cutoff στο 0.15 για να εμφανίζονται οι πηγές
retriever = index.as_retriever(
    similarity_top_k=6,
    embed_model=embed_model,
    node_postprocessors=[SimilarityPostprocessor(similarity_cutoff=0.15)]
)

def retrieve_context(question):
    nodes = retriever.retrieve(question)
    context = ""
    sources = []
    seen = set()
    for node in nodes:
        context += node.text + "\n\n"
        fname = node.metadata.get('file_name', 'unknown')
        if fname not in seen:
            seen.add(fname)
            sources.append(fname)
    return context, sources

def chat(message, history):
    context, sources = retrieve_context(message)

    system_prompt = (
        "You are an astronomy and astrophysics expert assistant. "
        "Your knowledge base consists only of scientific papers on black holes, dark energy, dark matter, and observational astronomy. "
        "IMPORTANT: You must ONLY answer questions related to these topics based on the provided context. "
        "If a question is about unrelated topics (e.g., movies, people, general knowledge), "
        "respond with: 'I can only answer questions about astronomy and astrophysics. Please ask me about black holes, dark energy, dark matter, or related astronomical topics.' "
        "If a question is about astronomy but the context contains no relevant information, say: 'I don't have information about this topic in my sources.' "
        "Answer in a natural, conversational way.\n\n"
        f"Context:\n{context}"
    )

    messages = [{"role": "system", "content": system_prompt}]

    for h in history:
        user_content = h["content"]
        if isinstance(user_content, list):
            user_content = user_content[0].get("text", "") if user_content else ""
        messages.append({
            "role": h["role"],
            "content": user_content
        })

    messages.append({"role": "user", "content": message})

    # ΔΙΟΡΘΩΣΗ: Χρήση του σωστού ollama_client που ορίστηκε στην αρχή
    stream = ollama_client.chat(
        model="deepseek-r1:8b",
        messages=messages,
        stream=True
    )

    full_response = ""
    sources_text = ""
    if sources:
        sources_text = "\n\n---\n📄 **Sources:** " + ", ".join(sources)

    for chunk in stream:
        token = chunk["message"].get("content", "")
        if token:
            full_response += token
            # Στέλνουμε live την απάντηση μαζί με τις πηγές για να αποφευχθεί το UI timeout
            yield full_response + (sources_text if sources else "")

demo = gr.ChatInterface(
    fn=chat,
    title="🔭 Retrieval-Augmented Generation Astro-Assistant",
    description="Ask questions about black holes, dark energy, dark matter, etc.",
    examples=[
        "What is a black hole?",
        "What is dark energy?",
        "What are primordial black holes?",
    ]
)

if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=7860)