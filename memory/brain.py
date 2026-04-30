"""
Cognitive memory: JSONL event log + ChromaDB vector store for semantic search.
FIX-9:  corrected ChromaDB OllamaEmbeddingFunction import path for chromadb>=0.4
FIX-14: nomic-embed-text uses keep_alive=0 so it releases VRAM immediately after
        each embedding call, preventing conflict with cograg-gpu (23 GB MoE model).
"""
import json, os, time, hashlib, urllib.request
from pathlib import Path

DB_PATH = Path("./memory/cognition.jsonl")
_chroma = None


def _unload_embed_model():
    """Release nomic-embed-text VRAM immediately after use."""
    try:
        body = json.dumps({
            "model": "nomic-embed-text",
            "keep_alive": 0,
            "prompt": ""
        }).encode()
        req = urllib.request.Request(
            "http://localhost:11434/api/generate", data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=5):
            pass
    except Exception:
        pass  # best-effort; don't crash memory on cleanup failure

def _get_chroma():
    global _chroma
    if _chroma is None:
        try:
            import chromadb
            # FIX-9: import path changed in chromadb 0.4+
            try:
                from chromadb.utils.embedding_functions import OllamaEmbeddingFunction
            except ImportError:
                from chromadb.utils import embedding_functions
                OllamaEmbeddingFunction = embedding_functions.OllamaEmbeddingFunction

            client = chromadb.PersistentClient(path="./memory/chroma_mem")
            ef = OllamaEmbeddingFunction(
                url="http://localhost:11434/api/embeddings",
                model_name="nomic-embed-text"
            )
            _chroma = client.get_or_create_collection("cogmem", embedding_function=ef)
        except Exception as e:
            print(f"[memory] ChromaDB unavailable: {e}. Falling back to keyword search.")
    return _chroma

def write(entry: dict):
    os.makedirs("memory", exist_ok=True)
    record = {"t": time.time(), **entry}
    with open(DB_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
    text = entry.get("text") or entry.get("reasoning") or entry.get("query") or ""
    if text and len(text) > 10:
        try:
            c = _get_chroma()
            if c:
                uid = hashlib.md5(f"{record['t']}{text[:50]}".encode()).hexdigest()
                c.upsert(
                    ids=[uid],
                    documents=[text[:2000]],
                    metadatas=[{"t": record["t"], "event": entry.get("event", "?")}]
                )
                _unload_embed_model()  # free VRAM immediately after embedding
        except Exception:
            pass

def load() -> list:
    if not DB_PATH.exists():
        return []
    out = []
    with open(DB_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
    return out

def search(query: str, n: int = 5) -> list:
    try:
        c = _get_chroma()
        if c and c.count() > 0:
            res  = c.query(query_texts=[query], n_results=min(n, c.count()))
            _unload_embed_model()  # free VRAM before cograg-gpu loads
            docs  = res.get("documents", [[]])[0]
            metas = res.get("metadatas", [[]])[0]
            return [{"text": d, **m} for d, m in zip(docs, metas)]
    except Exception:
        pass
    # Fallback: keyword scan
    data   = load()
    terms  = query.lower().split()
    scored = [(sum(json.dumps(d).lower().count(t) for t in terms), d) for d in data]
    scored = [(s, d) for s, d in scored if s > 0]
    scored.sort(key=lambda x: x[0], reverse=True)
    return [d for _, d in scored[:n]]

def recent(n: int = 20) -> list:
    return sorted(load(), key=lambda x: x.get("t", 0), reverse=True)[:n]


# ── Autonomous maintenance functions (called by background_loop) ──────────────

def memory_consolidation(max_per_query: int = 3) -> dict:
    """Deduplicate JSONL: keep only the most recent max_per_query cycle_end entries
    per unique query. Prevents unbounded memory growth from repeated self-probes."""
    entries = load()
    if not entries:
        return {"removed": 0, "kept": 0}
    seen: dict = {}
    keep = []
    for e in sorted(entries, key=lambda x: x.get("t", 0), reverse=True):
        if e.get("event") == "cycle_end":
            q = e.get("query", "")
            if seen.get(q, 0) >= max_per_query:
                continue
            seen[q] = seen.get(q, 0) + 1
        keep.append(e)
    removed = len(entries) - len(keep)
    if removed > 0:
        keep_sorted = sorted(keep, key=lambda x: x.get("t", 0))
        os.makedirs("memory", exist_ok=True)
        with open(DB_PATH, "w", encoding="utf-8") as f:
            for e in keep_sorted:
                f.write(json.dumps(e) + "\n")
    return {"removed": removed, "kept": len(keep)}


def self_diagnosis() -> dict:
    """Check JSONL integrity, ChromaDB sync, and count persisted error entries."""
    report: dict = {
        "corrupt_lines": 0, "error_entries": 0,
        "chroma_count": 0, "jsonl_count": 0, "issues": []
    }
    if DB_PATH.exists():
        with open(DB_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                report["jsonl_count"] += 1
                try:
                    e = json.loads(line)
                    if any("[ollama error:" in str(v) for v in e.values()):
                        report["error_entries"] += 1
                except Exception:
                    report["corrupt_lines"] += 1
    try:
        c = _get_chroma()
        if c:
            report["chroma_count"] = c.count()
            _unload_embed_model()
    except Exception as ex:
        report["issues"].append(f"chroma_unavailable: {ex}")
    if report["corrupt_lines"] > 0:
        report["issues"].append(f"{report['corrupt_lines']} corrupt JSONL lines detected")
    if report["error_entries"] > 5:
        report["issues"].append(
            f"{report['error_entries']} entries contain ollama errors — model was unstable")
    drift = abs(report["jsonl_count"] - report["chroma_count"])
    if drift > 50:
        report["issues"].append(f"chroma/jsonl drift={drift} — run embedding_maintenance")
    return report


def embedding_maintenance() -> dict:
    """Find JSONL entries missing from ChromaDB and re-embed them."""
    c = _get_chroma()
    if not c:
        return {"synced": 0, "skipped": "chroma_unavailable"}
    try:
        existing = set(c.get(include=[])["ids"])
        _unload_embed_model()
    except Exception:
        return {"synced": 0, "skipped": "chroma_get_failed"}
    synced = 0
    for e in load():
        text = e.get("text") or e.get("reasoning") or e.get("query") or ""
        if not text or len(text) <= 10:
            continue
        uid = hashlib.md5(f"{e.get('t', 0)}{text[:50]}".encode()).hexdigest()
        if uid not in existing:
            try:
                c.upsert(
                    ids=[uid],
                    documents=[text[:2000]],
                    metadatas=[{"t": e.get("t", 0), "event": e.get("event", "?")}]
                )
                synced += 1
            except Exception:
                pass
    if synced > 0:
        _unload_embed_model()
    return {"synced": synced}


def cleanup_old_data(max_entries: int = 500) -> dict:
    """Trim JSONL to most recent max_entries. Remove corresponding ChromaDB docs."""
    entries = load()
    if len(entries) <= max_entries:
        return {"removed": 0, "kept": len(entries)}
    sorted_entries = sorted(entries, key=lambda x: x.get("t", 0))
    to_remove = sorted_entries[:-max_entries]
    to_keep   = sorted_entries[-max_entries:]
    c = _get_chroma()
    removed_chroma = 0
    if c:
        for e in to_remove:
            text = e.get("text") or e.get("reasoning") or e.get("query") or ""
            if text and len(text) > 10:
                uid = hashlib.md5(f"{e.get('t', 0)}{text[:50]}".encode()).hexdigest()
                try:
                    c.delete(ids=[uid])
                    removed_chroma += 1
                except Exception:
                    pass
        _unload_embed_model()
    os.makedirs("memory", exist_ok=True)
    with open(DB_PATH, "w", encoding="utf-8") as f:
        for e in to_keep:
            f.write(json.dumps(e) + "\n")
    return {"removed": len(to_remove), "kept": len(to_keep), "chroma_removed": removed_chroma}
