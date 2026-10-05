import os
import time
import json
import ollama
import chromadb
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.vector_stores.chroma import ChromaVectorStore
from rich.live import Live
from rich.markdown import Markdown
from rich.spinner import Spinner
from rich.console import Console
from rich.table import Table
from rich.console import Group

# -----------------------------------------------------------------------------
# 1. Configuration & Setup
# -----------------------------------------------------------------------------
OLLAMA_BASE_URL = "http://host.docker.internal:11434"
os.environ["OLLAMA_HOST"] = OLLAMA_BASE_URL
SELECTED_MODEL = os.getenv("LLM_MODEL", "deepseek-r1:7b")

console = Console(force_terminal=True)

# Δημιουργία φακέλου data
os.makedirs("data", exist_ok=True)

# -----------------------------------------------------------------------------
# 2. Embedding Model & Index Loading
# -----------------------------------------------------------------------------
Settings.embed_model = OllamaEmbedding(
    model_name="nomic-embed-text", 
    base_url=OLLAMA_BASE_URL,
    ollama_additional_kwargs={"keep_alive": 0}
)

chroma_client = chromadb.PersistentClient(path="./data/chroma_db")
chroma_collection = chroma_client.get_or_create_collection("rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

retriever = index.as_retriever(similarity_top_k=6, embed_model=Settings.embed_model)
node_processor = SimilarityPostprocessor(similarity_cutoff=0.4)

# -----------------------------------------------------------------------------
# 3. Visual History Configuration (Not fed to LLM)
# -----------------------------------------------------------------------------
MAX_HISTORY_TURNS = 5
HISTORY_FILE = "data/conversation_history.json"

if os.path.exists(HISTORY_FILE):
    with open(HISTORY_FILE, "r", encoding="utf-8") as f:
        try:
            conversation_history = json.load(f)
        except json.JSONDecodeError:
            conversation_history = []
else:
    conversation_history = []

# -----------------------------------------------------------------------------
# 4. Core Functions
# -----------------------------------------------------------------------------
def retrieve_context(question):
    """Retrieve and filter chunks based strictly on the current question."""
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

def chat(question):
    """Process the question statelessly, but save to visual history."""
    global conversation_history
    
    context, sources = retrieve_context(question)
    start = time.time()
    
    if not context.strip():
        answer = "I cannot answer this based on the provided sources."
        console.print(Group("[bold cyan]Assistant:[/bold cyan]", Markdown(answer)))
        elapsed = time.time() - start
        console.print(f"\n[dim]⏱ Time elapsed: {elapsed:.3f}s[/dim]\n")
        console.print("[dim]--- Sources ---[/dim]\n[dim]No sources passed the similarity threshold.[/dim]\n")
    else:
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

        # Το LLM βλέπει ΜΟΝΟ το system prompt και την τρέχουσα ερώτηση
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": question}
        ]

        client = ollama.Client(host=OLLAMA_BASE_URL)
        stream = client.chat(model=SELECTED_MODEL, messages=messages, stream=True, options={"temperature": 0.0})

        full_response = ""
        answer = ""
        thinking_spinner = Spinner("dots", text="Thinking...")
        
        # 1. ΠΡΟΣΘΗΚΗ: Αρχικοποίηση μεταβλητών για τα metrics
        ttft_sec = 0.0
        tokens_per_sec = 0.0

        def show_thinking_layout():
            grid = Table.grid(padding=(0, 1))
            grid.add_column(no_wrap=True)
            grid.add_column()
            grid.add_row("[bold cyan]Assistant:[/bold cyan]", thinking_spinner)
            return grid

        def show_answer_layout(final_text):
            return Group(
                "[bold cyan]Assistant:[/bold cyan]",
                Markdown(final_text)
            )

        with Live(show_thinking_layout(), refresh_per_second=15, console=console) as live:
            for chunk in stream:
                token = chunk["message"]["content"]
                full_response += token

                if "<think>" in full_response:
                    if "</think>" in full_response:
                        answer = full_response.split("</think>")[-1].lstrip()
                        if answer:
                            live.update(show_answer_layout(answer))
                        else:
                            live.update(show_thinking_layout())
                    else:
                        live.update(show_thinking_layout())
                else:
                    if full_response.strip():
                        answer = full_response.strip()
                        live.update(show_answer_layout(answer))
                    else:
                        live.update(show_thinking_layout())

                # 2. ΠΡΟΣΘΗΚΗ: Διάβασμα των metrics στο τελευταίο chunk
                if chunk.get("done"):
                    load_dur = chunk.get("load_duration", 0)
                    prompt_dur = chunk.get("prompt_eval_duration", 0)
                    eval_dur = chunk.get("eval_duration", 1)  # Το 1 αποτρέπει διαίρεση με το 0
                    eval_count = chunk.get("eval_count", 0)
                    
                    ttft_sec = (load_dur + prompt_dur) / 1e9
                    tokens_per_sec = eval_count / (eval_dur / 1e9)

        if not answer:
            answer = "The model was interrupted while thinking." if "<think>" in full_response else full_response.strip()

        elapsed = time.time() - start

        # 3. ΑΛΛΑΓΗ: Ενσωμάτωση των metrics στην εκτύπωση του τερματικού
        console.print(f"\n[dim]--- System Benchmarks ---[/dim]")
        console.print(f"[dim]⏱ TTFT: {ttft_sec:.2f} s | ⚡ Speed: {tokens_per_sec:.2f} t/s | ⏳ Total Time: {elapsed:.2f} s[/dim]\n")

        console.print("[dim]--- Sources ---[/dim]")
        for fname, page, score in sources:
            console.print(f"[dim]📄 {fname} (Page {page}) | score: {score:.3f}[/dim]")
        print()

    # --- ΑΠΟΘΗΚΕΥΣΗ ΙΣΤΟΡΙΚΟΥ ΣΤΟ JSON (Αποκλειστικά για προβολή) ---
    conversation_history.append({"role": "user", "content": question})
    conversation_history.append({"role": "assistant", "content": answer})
    
    if len(conversation_history) > MAX_HISTORY_TURNS * 2:
        conversation_history = conversation_history[-MAX_HISTORY_TURNS * 2:]
        
    with open(HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(conversation_history, f, indent=4, ensure_ascii=False)

    return answer

# -----------------------------------------------------------------------------
# 5. Main Loop
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    console.clear()
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("\t🔭 [bold cyan]Retrieval-Augmented Generation Astro-Assistant[/bold cyan]")
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("Ask questions about astronomy, astrophysics, cosmology, and lunar science.")
    console.print("Type 'clear' to reset visual history, or 'exit' to quit.\n")
    
    # Εμφάνιση παλιού ιστορικού αν υπάρχει
    if conversation_history:
        console.print("[dim]--- Previous Conversation Loaded ---[/dim]")
        for msg in conversation_history:
            role_label = "[bold cyan]You:[/bold cyan]" if msg["role"] == "user" else "[bold cyan]Assistant:[/bold cyan]"
            console.print(f"{role_label} {msg['content']}\n")
        console.print("[dim]----------------------------------------[/dim]\n")

    while True:
        try:
            console.print("[bold cyan]You: [/bold cyan]", end="")
            question = input().strip()
            
            if question.lower() == "exit":
                break
                
            if question.lower() == "clear":
                conversation_history = []
                if os.path.exists(HISTORY_FILE):
                    os.remove(HISTORY_FILE)
                console.print("[dim]Visual history cleared. Starting a fresh screen.[/dim]\n")
                continue
                
            if not question:
                continue

            console.print()
            chat(question)
            
        except KeyboardInterrupt:
            break
        except Exception as e:
            console.print(f"\n[bold red]Error:[/bold red] {str(e)}\n")