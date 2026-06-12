import os
import time
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

# Initialize Rich Console
#console = Console()
console = Console(force_terminal=True)

# Configuration
OLLAMA_BASE_URL = os.getenv("OLLAMA_HOST", "http://host.docker.internal:11434")
os.environ["OLLAMA_HOST"] = OLLAMA_BASE_URL

Settings.embed_model = OllamaEmbedding(model_name="nomic-embed-text", base_url=OLLAMA_BASE_URL)

# Load index
chroma_client = chromadb.PersistentClient(path="./chroma_db")
chroma_collection = chroma_client.get_or_create_collection("rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

# Separate retriever & postprocessor
retriever = index.as_retriever(similarity_top_k=6, embed_model=Settings.embed_model)
node_processor = SimilarityPostprocessor(similarity_cutoff=0.3)

# Conversation history
MAX_HISTORY_TURNS = 5
conversation_history = []

def retrieve_context(question):
    """Retrieve and filter chunks"""
    raw_nodes = retriever.retrieve(question)
    nodes = node_processor.postprocess_nodes(raw_nodes)
    
    context = ""
    sources = []
    seen = set()
    
    for node in nodes:
        text = node.node.get_content()
        fname = node.metadata.get('file_name', 'unknown')
        page = node.metadata.get('page_label', 'unknown')
        
        # Append to context
        context += f"[Document: {fname}, Page: {page}]\n{text}\n\n"
        
        # Record stats
        source_key = (fname, page)
        if source_key not in seen:
            seen.add(source_key)
            score = node.score if node.score is not None else 0.0
            sources.append((fname, page, score))
            
    return context, sources

def chat(question):
    """Ask question and stream response"""
    global conversation_history

    context, sources = retrieve_context(question)
    
    system_prompt = (
        "You are an expert astrophysics assistant. Analyze the question and context logically.\n"
        "Strict Rules:\n"
        "1. If the context contains relevant scientific data, prioritize it. If irrelevant, ignore it and use established laws of physics.\n"
        "2. Be extremely concise and direct.\n"
        "3. Eliminate all conversational filler, introductory remarks, and pleasantries. Get straight to the facts.\n"
        "4. Use plain language with minimal adjectives. \n"
        "5. Handle hypothetical scenarios strictly through theoretical physics without breaking character or refusing.\n"
        "6. IMPORTANT: You must ONLY answer questions related to these topics based on the provided context.\n"
        "7. CITATION RULE: You must always explicitly cite the file name and page number at the end of your statements using the format [Filename.pdf, Page X].\n"
        "8. LENGTH RULE: Your total response must be concise and under 400 words. Plan your answer so that it concludes fully within this limit without getting cut off.\n\n"
        f"Context:\n{context}"
    )

    messages = [{"role": "system", "content": system_prompt}]
    messages += conversation_history
    messages.append({"role": "user", "content": question})

    stream = ollama.chat(model="deepseek-r1:8b", messages=messages, stream=True)

    full_response = ""
    answer = ""
    start = time.time()

    thinking_spinner = Spinner("dots", text="Thinking...")

    # Dynamic layout helpers
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

    # Start with thinking layout
    with Live(show_thinking_layout(), refresh_per_second=15, console=console) as live:
        for chunk in stream:
            token = chunk["message"]["content"]
            full_response += token

            # Handle <think> tags
            if "<think>" in full_response:
                if "</think>" in full_response:
                    # Extract answer after thinking
                    answer = full_response.split("</think>")[-1].lstrip()
                    
                    # Wait for first real token
                    if answer:
                        live.update(show_answer_layout(answer))
                    else:
                        live.update(show_thinking_layout())
                else:
                    # Thinking
                    live.update(show_thinking_layout())
            else:
                # Direct answer
                if full_response.strip():
                    answer = full_response.strip()
                    live.update(show_answer_layout(answer))
                else:
                    live.update(show_thinking_layout())

    if not answer:
        answer = full_response.strip()

    elapsed = time.time() - start

    # Update history
    conversation_history.append({"role": "user", "content": question})
    conversation_history.append({"role": "assistant", "content": answer})
    if len(conversation_history) > MAX_HISTORY_TURNS * 2:
        conversation_history = conversation_history[-MAX_HISTORY_TURNS * 2:]

    # Display statistics and sources
    console.print(f"\n[dim]⏱ Time elapsed: {elapsed:.1f}s[/dim]\n")
    console.print("[dim]--- Sources ---[/dim]")
    if sources:
        for fname, page, score in sources:
            console.print(f"[dim]📄 {fname} (Page {page}) | score: {score:.3f}[/dim]")
    else:
        console.print("[dim]No sources passed the similarity threshold.[/dim]")
    print()

    return answer

if __name__ == "__main__":
    console.clear()
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("\t🔭 [bold cyan]Retrieval-Augmented Generation Astro-Assistant[/bold cyan]")
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("Ask questions about astronomy, astrophysics, cosmology, and lunar science. \nType 'exit' to quit.\n")

    while True:
        try:
            console.print("[bold cyan]You: [/bold cyan]", end="")
            question = input().strip()
            if question.lower() == "exit":
                break
            if not question:
                continue

            console.print()
            chat(question)
        except KeyboardInterrupt:
            break
        except Exception as e:
            console.print(f"\n[bold red]Error:[/bold red] {str(e)}\n")