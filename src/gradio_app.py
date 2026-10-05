import os
import time
import gradio as gr
import chromadb
import ollama
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.vector_stores.chroma import ChromaVectorStore

# Environment detection
OLLAMA_BASE_URL = "http://host.docker.internal:11434"
os.environ["OLLAMA_HOST"] = OLLAMA_BASE_URL
SELECTED_MODEL = os.getenv("LLM_MODEL", "deepseek-r1:7b")

print(f"[INFO] Connecting to Ollama at: {OLLAMA_BASE_URL}")

# Init embedding model
Settings.embed_model = OllamaEmbedding(
    model_name="nomic-embed-text", 
    base_url=OLLAMA_BASE_URL,
    ollama_additional_kwargs={"keep_alive": 0}
)

# Load index
chroma_client = chromadb.PersistentClient(path="./data/chroma_db")
chroma_collection = chroma_client.get_or_create_collection("rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

# Configure strict retrieval
retriever = index.as_retriever(similarity_top_k=6, embed_model=Settings.embed_model)
node_processor = SimilarityPostprocessor(similarity_cutoff=0.45)

def retrieve_context(question):
    raw_nodes = retriever.retrieve(question)
    nodes = node_processor.postprocess_nodes(raw_nodes)
    
    context = ""
    sources = []
    seen = set()
    
    for node in nodes:
        text = node.node.get_content()
        fname = node.metadata.get('file_name', 'unknown')
        page = node.metadata.get('page_label', 'unknown')
        
        context += f"[Document: {fname}, Page: {page}]\n{text}\n\n"
        
        source_key = (fname, page)
        if source_key not in seen:
            seen.add(source_key)
            score = node.score if node.score is not None else 0.0
            sources.append((fname, page, score))
            
    return context, sources

def chat(message, history):
    start = time.time()
    context, sources = retrieve_context(message)

    # Early exit if no relevant context is found (Zero Hallucination state)
    if not context.strip():
        elapsed = time.time() - start
        yield (
            "I cannot answer this based on the provided sources.\n\n"
            "---\n"
            "**System Benchmarks:**\n"
            f"⏱ TTFT: 0.00 s | ⚡ Speed: 0.00 t/s | ⏳ Total: {elapsed:.2f} s\n\n"
            "*No sources passed the 0.4 similarity threshold.*"
        )
        return

    system_prompt = (
        "You are a strict astronomy/astrophysics research assistant. Your sole purpose is to answer questions based exactly on the provided context.\n"
        "Strict Rules:\n"
        "1. If the provided context does not contain the answer, you must reply only with: 'I cannot answer this based on the provided sources.' Do not guess.\n"
        "2. Be extremely concise and direct. Eliminate all conversational filler and pleasantries.\n"
        "3. Do not mention that you are reading from a context or a document. Just state the facts.\n"
        "4. Use plain language, minimal adjectives, and utilize structured bullet points for multi-part explanations.\n"
        "5. Always use the metric system for measurements.\n"
        "6. Length Rule: Your total response must be under 400 words.\n\n"
        f"Context:\n{context}"
    )

    # Pure stateless architecture: visual history is ignored by the LLM
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": message}
    ]

    client = ollama.Client(host=OLLAMA_BASE_URL)
    stream = client.chat(
        model=SELECTED_MODEL, 
        messages=messages, 
        stream=True, 
        options={"temperature": 0.0}
    )

    full_response = ""
    answer = ""
    ttft_sec = 0.0
    tokens_per_sec = 0.0

    for chunk in stream:
        token = chunk["message"].get("content", "")
        full_response += token

        # Parse out <think> tags in real-time
        if "<think>" in full_response and "</think>" not in full_response:
            yield "*(Thinking...)*"
            continue
            
        if "</think>" in full_response:
            answer = full_response.split("</think>")[-1].lstrip()
        else:
            answer = full_response.lstrip()

        # Capture metrics on final chunk
        if chunk.get("done"):
            load_dur = chunk.get("load_duration", 0)
            prompt_dur = chunk.get("prompt_eval_duration", 0)
            eval_dur = chunk.get("eval_duration", 1) 
            eval_count = chunk.get("eval_count", 0)
            
            ttft_sec = (load_dur + prompt_dur) / 1e9
            tokens_per_sec = eval_count / (eval_dur / 1e9)
            
            if not answer:
                answer = full_response.split("</think>")[-1].lstrip() if "</think>" in full_response else full_response.strip()

            elapsed = time.time() - start
            
            # Format Markdown footer
            footer = "\n\n---\n**System Benchmarks:**\n"
            footer += f"⏱ TTFT: {ttft_sec:.2f} s | ⚡ Speed: {tokens_per_sec:.2f} t/s | ⏳ Total: {elapsed:.2f} s\n\n"
            footer += "**Sources:**\n"
            for fname, page, score in sources:
                footer += f"- 📄 {fname} (Page {page}) | *Score: {score:.3f}*\n"
                
            yield answer + footer
            return

        # Progressive yield for Gradio UI
        if answer:
            yield answer

demo = gr.ChatInterface(
    fn=chat,
    title="🔭 Retrieval-Augmented Generation Astro-Assistant",
    description="Ask questions about astronomy, astrophysics, cosmology, and lunar science.",
    examples=[
        "What is a black hole?",
        "What are primordial black holes?",
        "What can you tell me about dark energy?"
    ]
)

if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=7860, share=True)