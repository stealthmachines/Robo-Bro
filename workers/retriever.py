"""
FIX-10: langchain-community 0.2+ moved some classes; use try/except to handle
both old and new import paths gracefully.
"""
import pickle, sys
sys.path.insert(0, ".")

try:
    from langchain_chroma import Chroma
except ImportError:
    from langchain_community.vectorstores import Chroma

try:
    from langchain_ollama import OllamaEmbeddings
except ImportError:
    from langchain_community.embeddings import OllamaEmbeddings

_cache = {}

def _load():
    if "vs" not in _cache:
        emb = OllamaEmbeddings(model="nomic-embed-text", base_url="http://localhost:11434")
        _cache["vs"] = Chroma(persist_directory="./chroma_db", embedding_function=emb)
        try:
            d = pickle.load(open("bm25_index.pkl", "rb"))
            _cache["bm25"]   = d["bm25"]
            _cache["chunks"] = d["chunks"]
        except Exception:
            _cache["bm25"]   = None
            _cache["chunks"] = []
    return _cache

def _rrf(lists, k=60):
    scores, docs = {}, {}
    for lst in lists:
        for rank, doc in enumerate(lst):
            key = doc.page_content[:120]
            scores[key] = scores.get(key, 0) + 1 / (rank + k)
            docs[key]   = doc
    return [docs[k] for k, _ in sorted(scores.items(), key=lambda x: x[1], reverse=True)]

def retrieve(query, top_k=6):
    c      = _load()
    dense  = c["vs"].similarity_search(query, k=top_k)
    sparse = []
    if c["bm25"]:
        sc     = c["bm25"].get_scores(query.lower().split())
        idx    = sorted(range(len(sc)), key=lambda i: sc[i], reverse=True)[:top_k]
        sparse = [c["chunks"][i] for i in idx]
    return _rrf([dense, sparse])[:top_k]
