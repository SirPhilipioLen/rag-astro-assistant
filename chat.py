import os
import time
import ollama
import chromadb
import subprocess
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.embeddings.ollama import OllamaEmbedding
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.vector_stores.chroma import ChromaVectorStore
from rich.live import Live
from rich.markdown import Markdown
from rich.spinner import Spinner
from rich.console import Console

# Αρχικοποίηση Rich Console για όμορφο format στο τερματικό
console = Console()

# Κλείδωμα του Ollama Host στο localhost των Windows
OLLAMA_BASE_URL = os.getenv("OLLAMA_HOST", "http://host.docker.internal:11434")
os.environ["OLLAMA_HOST"] = OLLAMA_BASE_URL

# Settings - Αρχικοποίηση του embedding μοντέλου
embed_model = OllamaEmbedding(model_name="nomic-embed-text", base_url=OLLAMA_BASE_URL)
Settings.embed_model = embed_model

# Φόρτωση του index από τη ChromaDB των Windows
chroma_client = chromadb.PersistentClient(path="./chroma_db")
chroma_collection = chroma_client.get_or_create_collection("astro_rag_corpus")
vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
storage_context = StorageContext.from_defaults(vector_store=vector_store)
index = VectorStoreIndex.from_vector_store(vector_store, storage_context=storage_context)

# ΔΙΟΡΘΩΣΗ: Προσθήκη του embed_model στον retriever για αποφυγή runtime mismatch σφαλμάτων
retriever = index.as_retriever(
    similarity_top_k=6,
    embed_model=embed_model,
    node_postprocessors=[SimilarityPostprocessor(similarity_cutoff=0.3)]
)

# Ιστορικό συνομιλίας
conversation_history = []

def retrieve_context(question):
    """Ανάκτηση σχετικών chunks από τη ChromaDB"""
    nodes = retriever.retrieve(question)
    context = ""
    sources = []
    seen = set()
    for node in nodes:
        context += node.text + "\n\n"
        fname = node.metadata.get('file_name', 'unknown')
        if fname not in seen:
            seen.add(fname)
            score = node.score if node.score is not None else 0.0
            sources.append((fname, score))
    return context, sources

def chat(question):
    """Υποβολή ερώτησης και streaming της απάντησης στο τερματικό"""
    global conversation_history

    # 1. Ανάκτηση Context
    context, sources = retrieve_context(question)

    #2. Χτίσιμο του System Prompt
    system_prompt = (
        "You are an astronomy and astrophysics expert assistant. "
        "Your knowledge base consists only of scientific papers on black holes, dark energy, dark matter, and observational astronomy. "
        "IMPORTANT: You must ONLY answer questions related to these topics based on the provided context. "
        "If a question is about unrelated topics (e.g., movies, people, general knowledge), "
        "respond with: 'I can only answer questions about astronomy and astrophysics. Please ask me about black holes, dark energy, dark matter, or related astronomical topics.' "
        "If a question is about astronomy/astrophysics but the context contains no relevant information, say: 'I don't have information about this topic in my sources.' "
        "Answer in a natural, conversational way.\n\n"
        f"Context:\n{context}"
    )
# 
    # system_prompt = (
    #     "You are an expert astrophysics assistant. Analyze the question and context logically.\n"
    #     "Strict Rules:\n"
    #     "1. If the context contains relevant scientific data, prioritize it. If irrelevant, ignore it and use established laws of physics.\n"
    #     "2. Be extremely concise and direct.\n"
    #     "3. Eliminate all conversational filler, introductory remarks, and pleasantries. Get straight to the facts.\n"
    #     "4. Use plain language with minimal adjectives. Avoid dense walls of text.\n"
    #     "5. Handle hypothetical scenarios strictly through theoretical physics without breaking character or refusing.\n\n"
    #     "6. IMPORTANT: You must ONLY answer questions related to these topics based on the provided context.\n"
    #     "If a question is about unrelated topics (e.g., movies, people, general knowledge)\n"
    #     f"Context:\n{context}"
    # )

    messages = [{"role": "system", "content": system_prompt}]
    messages += conversation_history
    messages.append({"role": "user", "content": question})

    # 3. Streaming από το Ollama των Windows
    stream = ollama.chat(
        model="deepseek-r1:8b",
        messages=messages,
        stream=True
    )

    full_response = ""
    answer = ""
    in_think = False
    thinking_done = False
    start = time.time()

    with Live(refresh_per_second=15, console=console) as live:
        for chunk in stream:
            token = chunk["message"]["content"]
            full_response += token

            # Διαχείριση των <think> tags του DeepSeek-R1
            if "<think>" in full_response and not thinking_done:
                in_think = True

            if "</think>" in full_response and in_think:
                in_think = False
                thinking_done = True

            if in_think:
                live.update(Spinner("dots", text=" Thinking..."))
            elif thinking_done:
                answer = full_response.split("</think>")[-1].strip()
                live.update(Markdown(answer))
            else:
                live.update(Markdown(full_response))

    if not thinking_done:
        answer = full_response.strip()

    elapsed = time.time() - start

    # Ενημέρωση του ιστορικού για το επόμενο turn
    conversation_history.append({"role": "user", "content": question})
    conversation_history.append({"role": "assistant", "content": answer})

    # Εμφάνιση στατιστικών και πηγών
    console.print(f"\n[dim]⏱ Time elapsed: {elapsed:.1f}s[/dim]\n")
    console.print("[dim]--- Sources ---[/dim]")
    if sources:
        for fname, score in sources:
            console.print(f"[dim]📄 {fname} | score: {score:.3f}[/dim]")
    else:
        console.print("[dim]No sources passed the similarity threshold.[/dim]")
    print()

    return answer

# Main Loop της εφαρμογής τερματικού
if __name__ == "__main__":
    subprocess.run(["clear"])
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("\t🔭 [bold cyan]Retrieval-Augmented Generation Astro-Assistant[/bold cyan]")
    console.print("[bold cyan]==================================================================[/bold cyan]")
    console.print("Ask questions about black holes, dark energy, dark matter, and the \nArtemis mission. Type 'exit' to quit.\n")

    while True:
        try:
            console.print("[bold cyan]You: [/bold cyan]", end="")
            question = input().strip()
            if question.lower() == "exit":
                break
            if not question:
                continue

            console.print("\n[bold cyan]Assistant:[/bold cyan]")
            chat(question)
        except KeyboardInterrupt:
            break
        except Exception as e:
            console.print(f"\n[bold red]Error:[/bold red] {str(e)}\n")