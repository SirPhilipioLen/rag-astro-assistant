import os
import gradio as gr
import chromadb
from ollama import Client
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.vector_stores.chroma import ChromaVectorStore

# Environment detection
if os.path.exists("/.dockerenv"):
    OLLAMA_BASE_URL = os.getenv("OLLAMA_HOST", "http://host.docker.internal:11434")
else:
    OLLAMA_BASE_URL = "http://127.0.0.1:11434"

print(f"[INFO] Connecting to Ollama at: {OLLAMA_BASE_URL}")

# Init client & embedding
ollama_client = Client(host=OLLAMA_BASE_URL)
embed_model = OllamaEmbedding(model_name="nomic-embed-text", base_url=OLLAMA_BASE_URL)
Settings.embed_model = embed_model

# Load index
chroma_client = chromadb.PersistentClient(path="./chroma_db")
chroma_collection = chroma_client.get_or_create_collection("astro_rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

# Separate retriever & postprocessor to apply cutoff
retriever = index.as_retriever(similarity_top_k=6, embed_model=embed_model)
node_processor = SimilarityPostprocessor(similarity_cutoff=0.15)

def retrieve_context(question):
    raw_nodes = retriever.retrieve(question)
    # Filter nodes by score
    nodes = node_processor.postprocess_nodes(raw_nodes)
    
    context = ""
    sources = []
    seen = set()
    for node in nodes:
        text = node.node.get_content()
        fname = node.metadata.get('file_name', 'unknown')
        page = node.metadata.get('page_label', 'unknown')
        
        context += f"[Document: {fname}, Page: {page}]\n{text}\n\n"
        
        source_key = f"{fname} (Page {page})"
        if source_key not in seen:
            seen.add(source_key)
            sources.append(source_key)
    return context, sources

def chat(message, history):
    context, sources = retrieve_context(message)

    system_prompt = (
        "You are an expert astrophysics assistant. Analyze the question and context logically.\n"
        "Strict Rules:\n"
        "1. If the context contains relevant scientific data, prioritize it. If irrelevant, ignore it and use established laws of physics.\n"
        "2. Be extremely concise and direct.\n"
        "3. Eliminate all conversational filler, introductory remarks, and pleasantries. Get straight to the facts.\n"
        "4. Use plain language with minimal adjectives.\n"
        "5. Handle hypothetical scenarios strictly through theoretical physics without breaking character or refusing.\n"
        "6. IMPORTANT: You must ONLY answer questions related to these topics based on the provided context.\n"
        "7. CITATION RULE: You must always explicitly cite the file name and page number at the end of your statements using the format [Filename.pdf, Page X].\n"
        "8. LENGTH RULE: Your total response must be concise and under 400 words. Plan your answer so that it concludes fully within this limit without getting cut off.\n\n"
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
            # Gradio text generation
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