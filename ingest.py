"""
FIX-11: Chroma.persist() removed in chromadb 0.4+; PersistentClient auto-persists.
"""
import sys, pickle
sys.path.insert(0, ".")

try:
    from langchain_chroma import Chroma
except ImportError:
    from langchain_community.vectorstores import Chroma

try:
    from langchain_ollama import OllamaEmbeddings
except (ImportError, Exception):
    from langchain_community.embeddings import OllamaEmbeddings  # type: ignore

from langchain_text_splitters import RecursiveCharacterTextSplitter
from rank_bm25 import BM25Okapi

def ingest():
    import glob as _glob
    print("Loading ./docs/ ...")
    from langchain_community.document_loaders import TextLoader
    from pathlib import Path as _Path
    raw_docs = []
    for ext in ("*.md", "*.txt"):
        for p in _Path("./docs").rglob(ext):
            try:
                raw_docs.extend(TextLoader(str(p), encoding="utf-8").load())
            except Exception as e:
                print(f"  skip {p}: {e}")
    if not raw_docs:
        print("No docs found in ./docs/")
        return
    chunks = RecursiveCharacterTextSplitter(
        chunk_size=512, chunk_overlap=64
    ).split_documents(raw_docs)
    print(f"  {len(chunks)} chunks from {len(raw_docs)} docs")
    emb = OllamaEmbeddings(model="nomic-embed-text", base_url="http://localhost:11434")
    # FIX-11: PersistentClient auto-persists; no .persist() call needed
    Chroma.from_documents(chunks, emb, persist_directory="./chroma_db")
    bm25 = BM25Okapi([c.page_content.lower().split() for c in chunks])
    pickle.dump({"bm25": bm25, "chunks": chunks}, open("bm25_index.pkl", "wb"))
    print("Done.")

if __name__ == "__main__":
    ingest()
