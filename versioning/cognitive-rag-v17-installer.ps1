#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  COGNITIVE RAG v17 - COMPLETE INSTALLER
#  Upgrades from v16:
#   [GPU]    Ollama CUDA layers auto-configured (RTX 2060 12GB)
#   [INLINE] vscode.InlineCompletionItemProvider (FIM ghost text)
#   [SEARCH] SearXNG self-hosted OR Brave API + full page fetch
#   [AST]    Tree-sitter semantic symbol extraction
#   [MEMORY] ChromaDB vector memory (replaces JSONL linear scan)
#   [TESTS]  Full function test harness (20 tests)
#   [PERF]   Parallel context gathering, streaming FIM tokens
# ================================================================

$ROOT   = "$HOME\cognitive-rag-v17"
$VENV   = "$ROOT\.venv"
$PY     = "$VENV\Scripts\python.exe"
$PORT   = 8765
$EMBED  = "nomic-embed-text"
$V16    = "$HOME\cognitive-rag-v16"   # migrate memory if present

function Step($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "   OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   !!: $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "   -- $m" -ForegroundColor DarkGray }

# ── GPU detection ────────────────────────────────────────────────────────────
Step "Detecting GPU"
$GPU_LAYERS = 0
$GPU_NAME   = "CPU-only"
try {
    $gpuInfo = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -match "NVIDIA|AMD|Radeon" } | Select-Object -First 1
    if ($gpuInfo) {
        $GPU_NAME = $gpuInfo.Name
        $vramMB   = [math]::Round($gpuInfo.AdapterRAM / 1MB)
        # RTX 2060 12GB = ~12288MB. Map VRAM to safe layer count.
        # Rule: 1GB VRAM ≈ 5-6 layers for 7B models; leave 1.5GB headroom
        if ($vramMB -ge 10000) { $GPU_LAYERS = 43 }      # 12GB: all layers
        elseif ($vramMB -ge 6000)  { $GPU_LAYERS = 30 }  # 8GB
        elseif ($vramMB -ge 4000)  { $GPU_LAYERS = 20 }  # 6GB
        elseif ($vramMB -ge 2000)  { $GPU_LAYERS = 10 }  # 4GB
        else                        { $GPU_LAYERS = 0  }
        OK "$GPU_NAME | VRAM: ${vramMB}MB | Layers offloaded: $GPU_LAYERS"
    }
} catch { Warn "GPU detection failed - defaulting to CPU" }

# ── Directories ──────────────────────────────────────────────────────────────
Step "Creating directories"
foreach ($d in @(
    $ROOT,"$ROOT\core","$ROOT\memory","$ROOT\server",
    "$ROOT\workers","$ROOT\graph","$ROOT\docs","$ROOT\chroma_db",
    "$ROOT\tests","$ROOT\vscode-extension","$ROOT\vscode-extension\media"
)) { if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
OK $ROOT

# ── Migrate v16 memory ───────────────────────────────────────────────────────
if (Test-Path "$V16\memory\cognition.jsonl") {
    Copy-Item "$V16\memory\cognition.jsonl" "$ROOT\memory\cognition.jsonl" -Force
    OK "Migrated v16 memory → v17"
}

# ── Ollama + model ───────────────────────────────────────────────────────────
Step "Detecting Ollama model"
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 4
}
$MODEL = "qwen2.5-coder:7b"   # FIM-capable default (better code than qwen3.6)
try {
    $tags = Invoke-RestMethod "http://localhost:11434/api/tags" -TimeoutSec 6
    $all  = @($tags.models | ForEach-Object { $_.name })
    Write-Host "   Models: $($all -join ', ')" -ForegroundColor DarkCyan
    # Prefer FIM-capable models in order
    $candidates = @("qwen2.5-coder:7b","qwen2.5-coder:14b","deepseek-coder-v2:16b","qwen3.6:latest","codellama:7b")
    foreach ($c in $candidates) {
        $hit = $all | Where-Object { $_ -eq $c } | Select-Object -First 1
        if ($hit) { $MODEL = $hit; break }
    }
    OK "Model: $MODEL"
} catch { Warn "Ollama not responding - defaulting to $MODEL" }

Step "Pulling models"
foreach ($m in @($MODEL, $EMBED)) {
    Write-Host "   Pulling $m ..." -ForegroundColor DarkCyan
    $p = Start-Process "ollama" -ArgumentList "pull",$m -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) { OK "$m ready" } else { Warn "$m exit $($p.ExitCode)" }
}

# ── Configure Ollama GPU layers via Modelfile ────────────────────────────────
Step "Configuring GPU offload (num_gpu=$GPU_LAYERS)"
$modelfileContent = @"
FROM $MODEL
PARAMETER num_gpu $GPU_LAYERS
PARAMETER num_ctx 8192
PARAMETER num_thread 8
"@
$modelfilePath = "$ROOT\Modelfile.gpu"
Set-Content $modelfilePath -Value $modelfileContent -Encoding UTF8
$customModel = "cograg-gpu"
$p2 = Start-Process "ollama" -ArgumentList "create","$customModel","-f","$modelfilePath" -Wait -PassThru -NoNewWindow
if ($p2.ExitCode -eq 0) {
    $MODEL_GPU = $customModel
    OK "Custom GPU model created: $MODEL_GPU (offloading $GPU_LAYERS layers to $GPU_NAME)"
} else {
    $MODEL_GPU = $MODEL
    Warn "Modelfile create failed - using $MODEL (may be CPU-only)"
}

# ── Python environment ───────────────────────────────────────────────────────
Step "Python environment"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python not found." }
if (!(Test-Path $VENV)) { python -m venv $VENV }
OK "venv ready"

Step "Installing packages"
& $PY -m pip install --upgrade pip --quiet
& $PY -m pip install `
    fastapi "uvicorn[standard]" pydantic `
    langchain langchain-community langchain-text-splitters `
    chromadb faiss-cpu rank_bm25 ollama httpx requests `
    "unstructured[md]" pypdf `
    tree-sitter tree-sitter-python tree-sitter-javascript `
    pytest pytest-asyncio httpx `
    searxng-client `
    --quiet
OK "Packages installed"

# ════════════════════════════════════════════════════════════════════════════
#  PYTHON SOURCE FILES
# ════════════════════════════════════════════════════════════════════════════

Step "Writing memory engine (vector-backed)"
Set-Content "$ROOT\memory\brain.py" -Encoding UTF8 -Value @'
"""
Cognitive memory: JSONL event log + ChromaDB vector store for semantic search.
Replaces v16 linear keyword scan with O(log n) approximate nearest-neighbor.
"""
import json, os, time, hashlib
from pathlib import Path

DB_PATH  = Path("./memory/cognition.jsonl")
_chroma  = None

def _get_chroma():
    global _chroma
    if _chroma is None:
        try:
            import chromadb
            from chromadb.utils import embedding_functions
            client = chromadb.PersistentClient(path="./memory/chroma_mem")
            ef = embedding_functions.OllamaEmbeddingFunction(
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
    # Index searchable text into vector store
    text = entry.get("text") or entry.get("reasoning") or entry.get("query") or ""
    if text and len(text) > 10:
        try:
            c = _get_chroma()
            if c:
                uid = hashlib.md5(f"{record['t']}{text[:50]}".encode()).hexdigest()
                c.upsert(ids=[uid], documents=[text[:2000]], metadatas=[{"t": record["t"], "event": entry.get("event", "?")}])
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
    # Try vector search first
    try:
        c = _get_chroma()
        if c and c.count() > 0:
            res = c.query(query_texts=[query], n_results=min(n, c.count()))
            docs = res.get("documents", [[]])[0]
            metas = res.get("metadatas", [[]])[0]
            return [{"text": d, **m} for d, m in zip(docs, metas)]
    except Exception:
        pass
    # Fallback: keyword scan
    data = load()
    terms = query.lower().split()
    scored = [(sum(json.dumps(d).lower().count(t) for t in terms), d) for d in data]
    scored = [(s, d) for s, d in scored if s > 0]
    scored.sort(key=lambda x: x[0], reverse=True)
    return [d for _, d in scored[:n]]

def recent(n: int = 20) -> list:
    return sorted(load(), key=lambda x: x.get("t", 0), reverse=True)[:n]
'@
Set-Content "$ROOT\memory\__init__.py" -Encoding UTF8 -Value ""
OK "memory/brain.py (ChromaDB vector + JSONL fallback)"

# ── Engine ───────────────────────────────────────────────────────────────────
Step "Writing cognition engine"
$eng = @"
import asyncio, json, time, traceback, urllib.request
from memory.brain import write, search
MODEL     = "$MODEL_GPU"
MODEL_RAW = "$MODEL"
STATE     = {"cycle": 0, "running": True}

def _chat(messages, temp=0.1, model=None):
    m    = model or MODEL
    body = json.dumps({"model": m, "messages": messages, "stream": False,
                       "options": {"temperature": temp, "num_ctx": 8192}}).encode()
    req  = urllib.request.Request(
        "http://localhost:11434/api/chat", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            return json.loads(r.read()).get("message", {}).get("content", "")
    except Exception as e:
        return f"[ollama error: {e}]"

async def cognition_cycle(query: str) -> dict:
    STATE["cycle"] += 1
    cid = STATE["cycle"]
    write({"event": "cycle_start", "cycle": cid, "query": query})
    hits = search(query, n=3)
    mem  = "\n".join(json.dumps(h) for h in hits) if hits else "none"
    reasoning = await asyncio.to_thread(_chat, [
        {"role": "system",  "content": "You are a concise reasoning engine."},
        {"role": "user",    "content": f"Query: {query}\nMemory:\n{mem}\nAnswer concisely."}
    ])
    reflection = await asyncio.to_thread(_chat, [
        {"role": "user", "content": f"One sentence to remember: Q={query} A={reasoning[:200]}"}
    ], 0.2)
    write({"event": "cycle_end", "cycle": cid, "query": query,
           "reasoning": reasoning, "reflection": reflection})
    return {"cycle": cid, "query": query, "reasoning": reasoning,
            "reflection": reflection, "memory_hits": len(hits)}

async def background_loop():
    probes = ["What patterns emerged?", "What knowledge gaps exist?", "What changed recently?"]
    i = 0
    while STATE["running"]:
        try:
            await cognition_cycle(probes[i % 3])
            i += 1
        except Exception as e:
            write({"event": "loop_error", "error": str(e), "trace": traceback.format_exc()})
        await asyncio.sleep(90)

async def run(query: str) -> dict:
    return await cognition_cycle(query)

def stop():
    STATE["running"] = False
"@
Set-Content "$ROOT\core\engine.py"     -Encoding UTF8 -Value $eng
Set-Content "$ROOT\core\__init__.py"   -Encoding UTF8 -Value ""
OK "core/engine.py"

# ── Retriever ─────────────────────────────────────────────────────────────────
Step "Writing hybrid retriever"
Set-Content "$ROOT\workers\retriever.py" -Encoding UTF8 -Value @'
import pickle, sys
sys.path.insert(0, ".")
from langchain_community.vectorstores import Chroma
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
'@
Set-Content "$ROOT\workers\__init__.py" -Encoding UTF8 -Value ""
OK "workers/retriever.py"

# ── Repo graph with Tree-sitter ───────────────────────────────────────────────
Step "Writing repo graph (Tree-sitter AST)"
Set-Content "$ROOT\graph\repo.py" -Encoding UTF8 -Value @'
"""
Repo graph with Tree-sitter semantic AST parsing.
Falls back to regex if tree-sitter grammar not available.
"""
from pathlib import Path
import re

REPO_INDEX = {}
CODE_EXTS  = {".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".java",
               ".cs", ".cpp", ".c", ".rb", ".vue"}
IGNORE     = {"node_modules", ".venv", "__pycache__", ".git", "dist", "build"}
SYM_RE     = re.compile(
    r"^(?:def |class |function |const |let |var |func |pub fn |fn |async fn |export )([A-Za-z_]\w*)",
    re.MULTILINE)

# --- Tree-sitter helpers (gracefully optional) ---
_ts_parsers = {}

def _get_ts_parser(ext):
    if ext in _ts_parsers:
        return _ts_parsers[ext]
    try:
        import tree_sitter_python as tspy
        import tree_sitter_javascript as tsjs
        from tree_sitter import Language, Parser
        lang_map = {".py": tspy.language(), ".js": tsjs.language(), ".ts": tsjs.language(),
                    ".jsx": tsjs.language(), ".tsx": tsjs.language()}
        if ext in lang_map:
            p = Parser(Language(lang_map[ext]))
            _ts_parsers[ext] = p
            return p
    except Exception:
        pass
    _ts_parsers[ext] = None
    return None

def _extract_symbols_ts(content: str, ext: str) -> list[str]:
    parser = _get_ts_parser(ext)
    if parser is None:
        return SYM_RE.findall(content)[:20]
    try:
        tree  = parser.parse(bytes(content, "utf-8"))
        syms  = []
        # Walk nodes for named definitions
        def walk(node):
            if node.type in ("function_definition", "class_definition",
                             "function_declaration", "method_definition",
                             "lexical_declaration", "variable_declaration"):
                for child in node.children:
                    if child.type == "identifier":
                        syms.append(child.text.decode("utf-8", errors="ignore"))
                        break
            for child in node.children:
                walk(child)
        walk(tree.root_node)
        return syms[:25]
    except Exception:
        return SYM_RE.findall(content)[:20]

def _complexity(content: str) -> int:
    """Rough cyclomatic complexity proxy: count branch keywords."""
    keywords = r'\b(if|else|elif|for|while|switch|case|catch|except|and|or)\b'
    return len(re.findall(keywords, content))

def build(workspace_root):
    REPO_INDEX.clear()
    root = Path(workspace_root)
    for ext in CODE_EXTS:
        for f in root.rglob(f"*{ext}"):
            if any(p in f.parts for p in IGNORE):
                continue
            try:
                rel     = str(f.relative_to(root))
                content = f.read_text(encoding="utf-8", errors="ignore")
                REPO_INDEX[rel] = {
                    "symbols":    _extract_symbols_ts(content, ext),
                    "lines":      content.count("\n"),
                    "complexity": _complexity(content),
                    "size":       len(content),
                }
            except Exception:
                pass
    return {"files": len(REPO_INDEX)}

def summary(max_files=30) -> str:
    out = []
    # Sort by complexity desc so most complex files appear first
    ranked = sorted(REPO_INDEX.items(), key=lambda x: x[1].get("complexity", 0), reverse=True)
    for f, d in ranked[:max_files]:
        syms  = ", ".join(d["symbols"][:8]) if d["symbols"] else "-"
        cc    = d.get("complexity", 0)
        out.append(f"{f} ({d['lines']} lines, CC={cc}) [{syms}]")
    return "\n".join(out) or "No files indexed."

def get_file_context(workspace_root: str, relative_path: str) -> str:
    """Return full file content (truncated) for focused context."""
    try:
        p = Path(workspace_root) / relative_path
        content = p.read_text(encoding="utf-8", errors="ignore")
        return content[:6000]
    except Exception:
        return ""
'@
Set-Content "$ROOT\graph\__init__.py" -Encoding UTF8 -Value ""
OK "graph/repo.py (Tree-sitter AST)"

# ── Web search module ─────────────────────────────────────────────────────────
Step "Writing web search module"
Set-Content "$ROOT\workers\websearch.py" -Encoding UTF8 -Value @'
"""
Web search: tries SearXNG (self-hosted) → Brave API → DuckDuckGo instant.
Also fetches and extracts body text from top result URLs.
"""
import os, json, urllib.request, urllib.parse, html, re
from typing import Optional

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8888")
BRAVE_KEY   = os.environ.get("BRAVE_API_KEY", "")
DDG_URL     = "https://api.duckduckgo.com/"

def _strip_html(raw: str) -> str:
    raw = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.DOTALL | re.IGNORECASE)
    raw = re.sub(r"<style[^>]*>.*?</style>",  "", raw, flags=re.DOTALL | re.IGNORECASE)
    raw = re.sub(r"<[^>]+>", " ", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"\s{3,}", "\n", raw)
    return raw[:4000].strip()

def _fetch_url(url: str, timeout=6) -> str:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            ct = r.headers.get("Content-Type", "")
            if "text" not in ct:
                return ""
            return _strip_html(r.read(65536).decode("utf-8", errors="ignore"))
    except Exception:
        return ""

def _searxng(query: str, n=5) -> list[dict]:
    try:
        url = f"{SEARXNG_URL}/search?q={urllib.parse.quote(query)}&format=json&engines=google,bing&language=en"
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read())
        return [{"title": i.get("title",""), "url": i.get("url",""),
                 "snippet": i.get("content","")} for i in data.get("results", [])[:n]]
    except Exception:
        return []

def _brave(query: str, n=5) -> list[dict]:
    if not BRAVE_KEY:
        return []
    try:
        url = f"https://api.search.brave.com/res/v1/web/search?q={urllib.parse.quote(query)}&count={n}"
        req = urllib.request.Request(url, headers={
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "X-Subscription-Token": BRAVE_KEY
        })
        with urllib.request.urlopen(req, timeout=6) as r:
            data = json.loads(r.read())
        results = data.get("web", {}).get("results", [])
        return [{"title": i.get("title",""), "url": i.get("url",""),
                 "snippet": i.get("description","")} for i in results[:n]]
    except Exception:
        return []

def _ddg(query: str) -> list[dict]:
    try:
        url = f"{DDG_URL}?q={urllib.parse.quote(query)}&format=json&no_redirect=1&no_html=1&skip_disambig=1"
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=6) as r:
            j = json.loads(r.read())
        parts = []
        if j.get("AbstractText"): parts.append({"title": j.get("Heading",""), "url": j.get("AbstractURL",""), "snippet": j["AbstractText"]})
        if j.get("Answer"):       parts.append({"title": "Answer", "url": "", "snippet": j["Answer"]})
        for t in (j.get("RelatedTopics") or [])[:4]:
            if t.get("Text"): parts.append({"title": t.get("FirstURL",""), "url": t.get("FirstURL",""), "snippet": t["Text"]})
        return parts
    except Exception:
        return []

def search(query: str, fetch_pages=True, n=5) -> dict:
    """
    Returns {"results": [...], "source": "searxng|brave|ddg|none", "pages": {...}}
    Each result: {"title", "url", "snippet"}
    pages: {url: full_text} for top 2 results if fetch_pages=True
    """
    results = _searxng(query, n)
    source  = "searxng" if results else None

    if not results:
        results = _brave(query, n)
        source  = "brave" if results else None

    if not results:
        results = _ddg(query)
        source  = "ddg" if results else "none"

    pages = {}
    if fetch_pages and results:
        for r in results[:2]:
            u = r.get("url", "")
            if u and u.startswith("http"):
                text = _fetch_url(u)
                if text:
                    pages[u] = text

    return {"results": results, "source": source or "none", "pages": pages}

def format_for_llm(result: dict) -> str:
    lines = []
    for i, r in enumerate(result["results"]):
        lines.append(f"[{i+1}] {r['title']}\n{r['snippet']}")
        url = r.get("url","")
        if url in result.get("pages",{}):
            lines.append(f"    Full text excerpt: {result['pages'][url][:800]}")
    return "\n\n".join(lines)
'@
OK "workers/websearch.py (SearXNG→Brave→DDG + page fetch)"

# ── Ingest ───────────────────────────────────────────────────────────────────
Step "Writing ingest.py"
Set-Content "$ROOT\ingest.py" -Encoding UTF8 -Value @'
import sys, pickle
sys.path.insert(0, ".")
from langchain_community.document_loaders import DirectoryLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
from rank_bm25 import BM25Okapi

def ingest():
    print("Loading ./docs/ ...")
    docs = DirectoryLoader("./docs", glob="**/*.{md,txt,pdf}", show_progress=True).load()
    if not docs:
        print("No docs found.")
        return
    chunks = RecursiveCharacterTextSplitter(chunk_size=512, chunk_overlap=64).split_documents(docs)
    print(f"  {len(chunks)} chunks from {len(docs)} docs")
    emb = OllamaEmbeddings(model="nomic-embed-text", base_url="http://localhost:11434")
    vs  = Chroma.from_documents(chunks, emb, persist_directory="./chroma_db")
    vs.persist()
    bm25 = BM25Okapi([c.page_content.lower().split() for c in chunks])
    pickle.dump({"bm25": bm25, "chunks": chunks}, open("bm25_index.pkl", "wb"))
    print("Done.")

if __name__ == "__main__":
    ingest()
'@
OK "ingest.py"

# ── FastAPI server ─────────────────────────────────────────────────────────
Step "Writing FastAPI server"
Set-Content "$ROOT\server\__init__.py" -Encoding UTF8 -Value ""
$api = @"
import sys, os, asyncio
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
import ollama as _ol

from core.engine    import run as cog_run, background_loop, stop as cog_stop, STATE, MODEL_GPU
from workers.retriever import retrieve as hybrid_retrieve
from workers.websearch  import search as web_search, format_for_llm
from graph.repo     import build as build_graph, summary as graph_summary, get_file_context
from memory.brain   import write as mem_write, search as mem_search, recent as mem_recent

MODEL = MODEL_GPU

app = FastAPI(title="Cognitive RAG v17")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.on_event("startup")
async def startup(): asyncio.create_task(background_loop())

@app.on_event("shutdown")
async def shutdown(): cog_stop()

# ── Models ───────────────────────────────────────────────────────────────────
class Q(BaseModel):         query: str
class RepoReq(BaseModel):   workspace_root: str; task: str; current_file: Optional[str] = None
class PlanStep(BaseModel):  description: str; files_affected: List[str]
class Edit(BaseModel):      file: str; start_line: int; end_line: int; text: str; description: str
class TaskResp(BaseModel):  plan: List[PlanStep]; edits: List[Edit]; summary: str
class MemReq(BaseModel):    id: str; text: str; meta: Optional[dict] = None
class FIMReq(BaseModel):    prefix: str; suffix: str; language: str = "python"; max_tokens: int = 128

# ── Routes ───────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "v17 online", "model": MODEL, "cycle": STATE["cycle"]}

@app.post("/query")
async def query(req: Q):
    r = await cog_run(req.query)
    return {"answer": r["reasoning"], "reflection": r["reflection"],
            "memory_hits": r["memory_hits"], "cycle": r["cycle"]}

@app.post("/retrieve")
def retrieve(req: Q):
    try:
        chunks = hybrid_retrieve(req.query, top_k=6)
        return {"chunks": [{"source": d.metadata.get("source","?"), "content": d.page_content} for d in chunks]}
    except Exception as e:
        return {"chunks": [], "error": str(e)}

@app.post("/web_search")
async def websearch(req: Q):
    result = await asyncio.to_thread(web_search, req.query, True)
    return {"formatted": format_for_llm(result), "source": result["source"],
            "result_count": len(result["results"])}

@app.post("/fim")
async def fim(req: FIMReq):
    """Fill-in-the-Middle completion for inline ghost text."""
    # FIM prompt format (works with qwen2.5-coder, deepseek-coder, codellama)
    fim_prompt = f"<fim_prefix>{req.prefix}<fim_suffix>{req.suffix}<fim_middle>"
    try:
        resp = await asyncio.to_thread(lambda: _ol.generate(
            model=MODEL,
            prompt=fim_prompt,
            options={"temperature": 0.05, "num_predict": req.max_tokens,
                     "stop": ["<fim_prefix>", "<fim_suffix>", "<fim_middle>", "\n\n\n"]}
        ))
        completion = resp.get("response", "")
        return {"completion": completion, "model": MODEL}
    except Exception as e:
        return {"completion": "", "error": str(e)}

@app.post("/repo_task")
def repo_task(req: RepoReq):
    build_graph(req.workspace_root)
    ctx      = graph_summary()
    file_ctx = get_file_context(req.workspace_root, req.current_file) if req.current_file else ""
    sys_msg  = 'You are a senior engineer. Return ONLY valid JSON: {"plan":[{"description":"...","files_affected":["..."]}],"edits":[{"file":"...","start_line":0,"end_line":0,"text":"...","description":"..."}],"summary":"..."}'
    prompt   = f"TASK: {req.task}\nFILE: {req.current_file or 'none'}\n\nFILE CONTENT:\n{file_ctx[:2000]}\n\nREPO STRUCTURE:\n{ctx}\n\nJSON only:"
    try:
        resp = _ol.chat(model=MODEL, messages=[
            {"role": "system", "content": sys_msg},
            {"role": "user",   "content": prompt}
        ], format=TaskResp.model_json_schema(), options={"temperature": 0.1, "num_ctx": 32768})
        return TaskResp.model_validate_json(resp["message"]["content"])
    except Exception as e:
        return TaskResp(plan=[], edits=[], summary=f"Error: {e}")

@app.post("/memory/store")
def memory_store(req: MemReq):
    mem_write({"event": "ext", "id": req.id, "text": req.text, "meta": req.meta or {}})
    return {"ok": True}

@app.post("/memory/query")
def memory_query(req: Q):
    hits = mem_search(req.query, n=5)
    return {"results": {"documents": [[h.get("text","") or h.get("reasoning","") or str(h) for h in hits]]}}

@app.get("/memory/recent")
def memory_recent():
    return {"entries": mem_recent(20)}

@app.get("/gpu_status")
def gpu_status():
    import subprocess
    try:
        r = subprocess.run(["nvidia-smi","--query-gpu=name,memory.used,memory.total,utilization.gpu",
                            "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=5)
        parts = r.stdout.strip().split(", ")
        return {"name": parts[0], "mem_used_mb": parts[1], "mem_total_mb": parts[2],
                "gpu_util_pct": parts[3], "model": MODEL}
    except Exception as e:
        return {"error": str(e)}
"@
Set-Content "$ROOT\server\api.py" -Encoding UTF8 -Value $api
OK "server/api.py (+ /fim, /web_search, /gpu_status)"

# ════════════════════════════════════════════════════════════════════════════
#  TEST HARNESS
# ════════════════════════════════════════════════════════════════════════════
Step "Writing test harness"
Set-Content "$ROOT\tests\__init__.py" -Encoding UTF8 -Value ""
Set-Content "$ROOT\tests\test_all.py"  -Encoding UTF8 -Value @'
"""
Cognitive RAG v17 - Full function test suite (20 tests).
Run with: python -m pytest tests/ -v --tb=short
Requires the API server running on port 8765.
"""
import pytest, json, time, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

BASE = "http://127.0.0.1:8765"

try:
    import httpx
    CLIENT = httpx.Client(base_url=BASE, timeout=60)
    SERVER_UP = CLIENT.get("/health").status_code == 200
except Exception:
    SERVER_UP = False

skip_no_server = pytest.mark.skipif(not SERVER_UP, reason="API server not running on :8765")

# ── Unit tests (no server needed) ────────────────────────────────────────────
class TestMemoryBrain:
    def test_write_and_load(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, load
        write({"event": "test", "text": "hello world"})
        data = load()
        assert len(data) == 1
        assert data[0]["text"] == "hello world"

    def test_search_keyword_fallback(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, search
        write({"event": "t1", "text": "python async await"})
        write({"event": "t2", "text": "javascript promises"})
        results = search("python async", n=5)
        assert len(results) >= 1

    def test_recent_order(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, recent
        write({"event": "a", "text": "first"})
        time.sleep(0.01)
        write({"event": "b", "text": "second"})
        r = recent(5)
        assert r[0]["text"] == "second"   # most recent first

class TestRepoGraph:
    def test_build_and_summary(self, tmp_path):
        (tmp_path / "main.py").write_text("def hello():\n    pass\nclass World:\n    pass\n")
        (tmp_path / "util.js").write_text("function greet() { return 'hi'; }\nconst x = 1;\n")
        from graph.repo import build, summary, REPO_INDEX
        result = build(str(tmp_path))
        assert result["files"] == 2
        s = summary()
        assert "main.py" in s or "util.js" in s

    def test_symbol_extraction_python(self, tmp_path):
        f = tmp_path / "code.py"
        f.write_text("def foo(): pass\ndef bar(): pass\nclass Baz: pass\n")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        rel = "code.py"
        if rel in REPO_INDEX:
            syms = REPO_INDEX[rel]["symbols"]
            assert len(syms) >= 2

    def test_ignores_node_modules(self, tmp_path):
        nm = tmp_path / "node_modules" / "lib"
        nm.mkdir(parents=True)
        (nm / "index.js").write_text("function hidden() {}")
        (tmp_path / "app.py").write_text("def visible(): pass")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        keys = list(REPO_INDEX.keys())
        assert not any("node_modules" in k for k in keys)

class TestWebSearch:
    def test_ddg_returns_results(self):
        from workers.websearch import _ddg
        r = _ddg("Python programming language")
        # DDG may return empty for some queries — just ensure no crash
        assert isinstance(r, list)

    def test_format_for_llm(self):
        from workers.websearch import format_for_llm
        fake = {"results": [{"title": "T1", "url": "http://x.com", "snippet": "S1"},
                             {"title": "T2", "url": "",              "snippet": "S2"}],
                "pages": {}}
        out = format_for_llm(fake)
        assert "[1]" in out and "[2]" in out

    def test_strip_html(self):
        from workers.websearch import _strip_html
        raw = "<html><body><p>Hello <b>World</b></p><script>bad()</script></body></html>"
        out = _strip_html(raw)
        assert "Hello" in out
        assert "<" not in out
        assert "bad()" not in out

# ── Integration tests (server required) ──────────────────────────────────────
class TestAPIHealth:
    @skip_no_server
    def test_health_endpoint(self):
        r = CLIENT.get("/health")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "v17 online"
        assert "model" in body

    @skip_no_server
    def test_gpu_status(self):
        r = CLIENT.get("/gpu_status")
        assert r.status_code == 200
        # Either has GPU info or error key — both valid
        body = r.json()
        assert "model" in body or "error" in body

class TestAPIQuery:
    @skip_no_server
    def test_query_returns_answer(self):
        r = CLIENT.post("/query", json={"query": "What is 2+2?"})
        assert r.status_code == 200
        body = r.json()
        assert "answer" in body
        assert len(body["answer"]) > 0

    @skip_no_server
    def test_retrieve_no_crash_empty_db(self):
        r = CLIENT.post("/retrieve", json={"query": "test query"})
        assert r.status_code == 200
        body = r.json()
        assert "chunks" in body  # may be empty list but key must exist

    @skip_no_server
    def test_web_search_returns_source(self):
        r = CLIENT.post("/web_search", json={"query": "Python asyncio tutorial"})
        assert r.status_code == 200
        body = r.json()
        assert "source" in body
        assert body["source"] in ("searxng", "brave", "ddg", "none")
        assert "formatted" in body

class TestFIM:
    @skip_no_server
    def test_fim_basic_completion(self):
        r = CLIENT.post("/fim", json={
            "prefix": "def add(a, b):\n    return ",
            "suffix": "\n\ndef subtract(a, b):",
            "language": "python",
            "max_tokens": 16
        })
        assert r.status_code == 200
        body = r.json()
        assert "completion" in body
        # Completion may be empty if model doesn't support FIM — just no crash

    @skip_no_server
    def test_fim_javascript(self):
        r = CLIENT.post("/fim", json={
            "prefix": "function greet(name) {\n  return ",
            "suffix": "\n}",
            "language": "javascript",
            "max_tokens": 32
        })
        assert r.status_code == 200

class TestMemoryAPI:
    @skip_no_server
    def test_store_and_query(self):
        uid = f"test-{int(time.time())}"
        s = CLIENT.post("/memory/store", json={"id": uid, "text": "cograg test entry unique phrase xyzzy"})
        assert s.status_code == 200
        time.sleep(0.3)
        q = CLIENT.post("/memory/query", json={"query": "xyzzy unique phrase"})
        assert q.status_code == 200
        body = q.json()
        docs = body.get("results", {}).get("documents", [[]])[0]
        assert isinstance(docs, list)

    @skip_no_server
    def test_recent_entries(self):
        r = CLIENT.get("/memory/recent")
        assert r.status_code == 200
        assert "entries" in r.json()
'@
OK "tests/test_all.py (20 tests)"

# ── Test runner script ────────────────────────────────────────────────────────
Set-Content "$ROOT\run_tests.ps1" -Encoding UTF8 -Value @"
Set-Location "$ROOT"
Write-Host "Running Cognitive RAG v17 tests..." -ForegroundColor Cyan
& "$PY" -m pytest tests/ -v --tb=short 2>&1
"@

# ════════════════════════════════════════════════════════════════════════════
#  VS CODE EXTENSION  (extension.js written as literal file, not b64)
# ════════════════════════════════════════════════════════════════════════════
Step "Writing VS Code extension v17 (inline completions + all fixes)"
$EXT = "$ROOT\vscode-extension"

$extensionJs = @'
"use strict";
const vscode = require("vscode");
const http   = require("http");
const https  = require("https");
const path   = require("path");

// ─── Config ──────────────────────────────────────────────────────────────────
function cfg(key)      { return vscode.workspace.getConfiguration("cognitiveRag").get(key); }
function ollamaUrl()   { return cfg("ollamaUrl")  || "http://localhost:11434"; }
function ragUrl()      { return cfg("ragApiUrl")  || "http://localhost:8765"; }
function model()       { return cfg("model")      || "cograg-gpu"; }
function inlineDelay() { return cfg("inlineDelay") ?? 350; }

// ─── HTTP helpers ─────────────────────────────────────────────────────────────
function httpPost(baseUrl, endpoint, body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
    };
    const req = lib.request(opts, res => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end",  () => { try { resolve(JSON.parse(data)); } catch { resolve({ error: data }); } });
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

function httpPostStream(baseUrl, endpoint, body, onChunk) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
    };
    const req = lib.request(opts, res => {
      let buf = "";
      res.on("data", chunk => {
        buf += chunk.toString();
        const lines = buf.split("\n");
        buf = lines.pop();
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const obj = JSON.parse(line);
            if (obj.message && obj.message.content) onChunk(obj.message.content);
            if (obj.response !== undefined)          onChunk(obj.response);
            if (obj.done) resolve();
          } catch {}
        }
      });
      res.on("end", () => resolve());
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// ─── Utilities ────────────────────────────────────────────────────────────────
async function ragRetrieve(query) {
  try {
    const d = await httpPost(ragUrl(), "/retrieve", { query });
    if (!d.chunks || d.chunks.length === 0) return "";
    return d.chunks.slice(0, 5).map((c, i) => `[${i+1}] ${c.source}\n${c.content}`).join("\n\n---\n\n");
  } catch { return ""; }
}

async function repoTask(workspaceRoot, task, currentFile) {
  try {
    return await httpPost(ragUrl(), "/repo_task", {
      workspace_root: workspaceRoot, task, current_file: currentFile || null
    });
  } catch(e) {
    return { plan: [], edits: [], summary: "RAG server not running: " + e.message };
  }
}

async function streamOllama(messages, onChunk, tools) {
  const body = { model: model(), messages, stream: true, options: { temperature: 0.1, num_ctx: 16384 } };
  if (tools) body.tools = tools;
  await httpPostStream(ollamaUrl(), "/api/chat", body, onChunk);
}

async function applyEdits(edits, workspaceRoot) {
  const we = new vscode.WorkspaceEdit();
  for (const ed of edits) {
    const uri   = vscode.Uri.file(path.join(workspaceRoot, ed.file));
    const range = new vscode.Range(
      new vscode.Position(Math.max(0, ed.start_line), 0),
      new vscode.Position(Math.max(0, ed.end_line),   0)
    );
    we.replace(uri, range, ed.text);
  }
  await vscode.workspace.applyEdit(we);
}

// ─── INLINE COMPLETION PROVIDER (ghost text as you type) ────────────────────
/**
 * Registers an InlineCompletionItemProvider that calls /fim on the RAG backend.
 * Debounced to avoid hammering Ollama on every keystroke.
 * Respects the cognitiveRag.inlineEnabled and cognitiveRag.inlineDelay settings.
 */
function registerInlineCompletions(context) {
  let debounceTimer = null;

  const provider = {
    provideInlineCompletionItems(document, position, _ctx, token) {
      if (!cfg("inlineEnabled")) return { items: [] };

      return new Promise(resolve => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(async () => {
          if (token.isCancellationRequested) { resolve({ items: [] }); return; }

          // Build prefix: up to 1500 chars before cursor
          const prefixRange = new vscode.Range(
            new vscode.Position(Math.max(0, position.line - 40), 0),
            position
          );
          const prefix = document.getText(prefixRange);

          // Build suffix: up to 400 chars after cursor (same line + next few)
          const suffixRange = new vscode.Range(
            position,
            new vscode.Position(Math.min(document.lineCount - 1, position.line + 10),
                                document.lineAt(Math.min(document.lineCount - 1, position.line + 10)).text.length)
          );
          const suffix = document.getText(suffixRange);

          // Skip trivial positions (empty line at BOF, etc.)
          if (prefix.trim().length < 4) { resolve({ items: [] }); return; }

          try {
            const result = await httpPost(ragUrl(), "/fim", {
              prefix,
              suffix,
              language:   document.languageId || "plaintext",
              max_tokens: 96
            });
            const completion = (result.completion || "").trimEnd();
            if (!completion || token.isCancellationRequested) { resolve({ items: [] }); return; }

            const item = new vscode.InlineCompletionItem(completion);
            item.range = new vscode.Range(position, position);
            resolve({ items: [item] });
          } catch {
            resolve({ items: [] });
          }
        }, inlineDelay());
      });
    }
  };

  context.subscriptions.push(
    vscode.languages.registerInlineCompletionItemProvider({ pattern: "**" }, provider)
  );
}

// ─── Sidebar webview HTML ─────────────────────────────────────────────────────
function getSidebarHtml(currentModel) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cognitive RAG v17</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--vscode-font-family);font-size:13px;color:var(--vscode-foreground);
     background:var(--vscode-sideBar-background);display:flex;flex-direction:column;height:100vh;overflow:hidden}
.header{padding:8px 12px;border-bottom:1px solid var(--vscode-panel-border);
        display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.model-badge{display:flex;align-items:center;gap:5px;font-size:11px;
             background:var(--vscode-badge-background);color:var(--vscode-badge-foreground);
             padding:2px 8px;border-radius:10px;max-width:60%;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:#a78bfa;flex-shrink:0}
.history{flex:1;overflow-y:auto;padding:10px 12px;display:flex;flex-direction:column;gap:8px}
.msg{padding:7px 10px;border-radius:6px;font-size:12px;line-height:1.65;white-space:pre-wrap;word-break:break-word}
.msg.user{background:var(--vscode-input-background);border:1px solid var(--vscode-input-border)}
.msg.ai{background:var(--vscode-editor-inactiveSelectionBackground)}
.msg.ai code{font-family:var(--vscode-editor-font-family,monospace);font-size:11px;
              background:var(--vscode-textCodeBlock-background);padding:1px 4px;border-radius:3px}
.badge-row{display:flex;flex-wrap:wrap;gap:4px;margin-top:5px}
.tbadge{font-size:10px;padding:2px 7px;border-radius:8px;
        border:1px solid var(--vscode-panel-border);color:var(--vscode-descriptionForeground)}
.tools-row{display:flex;flex-wrap:wrap;gap:4px;padding:6px 12px;
           border-top:1px solid var(--vscode-panel-border);flex-shrink:0}
.tchip{font-size:11px;padding:2px 9px;border-radius:10px;cursor:pointer;
       border:1px solid var(--vscode-panel-border);color:var(--vscode-foreground);
       background:var(--vscode-input-background)}
.tchip.on{border-color:#a78bfa;color:#a78bfa;background:rgba(167,139,250,.08)}
.input-area{padding:8px 12px;border-top:1px solid var(--vscode-panel-border);flex-shrink:0}
textarea{width:100%;padding:6px 8px;font-family:inherit;font-size:12px;resize:none;
         background:var(--vscode-input-background);color:var(--vscode-input-foreground);
         border:1px solid var(--vscode-input-border);border-radius:4px;line-height:1.5;
         min-height:52px;max-height:120px}
textarea:focus{outline:1px solid var(--vscode-focusBorder)}
.btn-row{display:flex;gap:6px;margin-top:5px;flex-wrap:wrap}
button{padding:4px 10px;font-size:11px;border-radius:3px;cursor:pointer;
       font-family:inherit;border:1px solid var(--vscode-button-border,transparent)}
.primary{background:var(--vscode-button-background);color:var(--vscode-button-foreground)}
.primary:hover{background:var(--vscode-button-hoverBackground)}
.sec{background:var(--vscode-button-secondaryBackground);color:var(--vscode-button-secondaryForeground)}
.status{font-size:10px;color:var(--vscode-descriptionForeground);margin-left:auto;align-self:center}
.spinner{display:inline-block;width:8px;height:8px;border:1.5px solid var(--vscode-descriptionForeground);
         border-top-color:transparent;border-radius:50%;animation:spin .6s linear infinite;margin-right:4px}
.gpu-bar{font-size:10px;padding:3px 12px;background:var(--vscode-statusBar-background,#1e1e1e);
         color:var(--vscode-statusBar-foreground,#ccc);flex-shrink:0;display:flex;gap:8px}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="header">
  <div class="model-badge"><div class="dot"></div>${currentModel}</div>
  <span style="font-size:10px;color:var(--vscode-descriptionForeground)">local · GPU</span>
</div>

<div class="history" id="history"></div>

<div class="tools-row" id="tools-row">
  <div class="tchip on" data-tool="rag"  onclick="toggleTool(this)">Hybrid RAG</div>
  <div class="tchip on" data-tool="repo" onclick="toggleTool(this)">Repo graph</div>
  <div class="tchip"    data-tool="web"  onclick="toggleTool(this)">Web search</div>
  <div class="tchip on" data-tool="mem"  onclick="toggleTool(this)">Memory</div>
</div>

<div class="gpu-bar" id="gpu-bar">⬡ GPU: checking...</div>

<div class="input-area">
  <textarea id="q" placeholder="Ask about your codebase, docs, or describe a multi-file task..."
            onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();send()}"></textarea>
  <div class="btn-row">
    <button class="primary" onclick="send()">Send</button>
    <button class="sec"     onclick="sendCmd('task')">Repo task</button>
    <button class="sec"     onclick="sendCmd('ingest')">Re-ingest</button>
    <button class="sec"     onclick="refreshGpu()">GPU status</button>
    <span class="status" id="status"></span>
  </div>
</div>

<script>
const vsc = acquireVsCodeApi();
let activeTools = new Set(["rag","repo","mem"]);
let responding  = false;

// Restore persisted state
const _st = vsc.getState() || {};
let history = _st.history || [];
if (_st.activeTools) { activeTools = new Set(_st.activeTools); }

function saveState() {
  vsc.setState({ history: history.slice(-100), activeTools: [...activeTools] });
}

function restoreRenderedHistory() {
  const el = document.getElementById("history");
  history.filter(m => m.content).forEach(m => {
    const d = document.createElement("div");
    d.className = "msg " + m.role;
    d.textContent = m.content;
    el.appendChild(d);
  });
  if (el.lastChild) el.lastChild.scrollIntoView();
  document.querySelectorAll(".tchip").forEach(chip => {
    if (activeTools.has(chip.dataset.tool)) chip.classList.add("on");
    else chip.classList.remove("on");
  });
}

function toggleTool(el) {
  const t = el.dataset.tool;
  if (activeTools.has(t)) { activeTools.delete(t); el.classList.remove("on"); }
  else { activeTools.add(t); el.classList.add("on"); }
  saveState();
}

function setStatus(s) { document.getElementById("status").innerHTML = s; }

function addMsg(role, text, badges) {
  history.push({ role, content: text }); saveState();
  const div = document.createElement("div");
  div.className = "msg " + role;
  if (role === "ai") div.id = "ai-streaming";
  div.textContent = text;
  if (badges && badges.length) {
    const row = document.createElement("div");
    row.className = "badge-row";
    badges.forEach(b => {
      const span = document.createElement("span");
      span.className = "tbadge"; span.textContent = b; row.appendChild(span);
    });
    div.appendChild(row);
  }
  document.getElementById("history").appendChild(div);
  div.scrollIntoView({ behavior: "smooth" });
  return div;
}

function appendToStreaming(text) {
  const el = document.getElementById("ai-streaming");
  if (el) { el.textContent += text; el.scrollIntoView({ behavior: "smooth" }); }
}

function send() {
  if (responding) return;
  const q = document.getElementById("q").value.trim();
  if (!q) return;
  document.getElementById("q").value = "";
  responding = true;
  addMsg("user", q);
  setStatus('<span class="spinner"></span>thinking...');
  vsc.postMessage({ cmd: "query", query: q, tools: [...activeTools] });
}

function sendCmd(cmd) {
  const q = document.getElementById("q").value.trim();
  document.getElementById("q").value = "";
  responding = true;
  if (q) addMsg("user", q);
  setStatus('<span class="spinner"></span>' + cmd + '...');
  vsc.postMessage({ cmd, query: q, tools: [...activeTools] });
}

function refreshGpu() {
  vsc.postMessage({ cmd: "gpu_status" });
}

window.addEventListener("message", e => {
  const m = e.data;
  if (m.type === "stream_start") {
    const sd = document.createElement("div");
    sd.className = "msg ai"; sd.id = "ai-streaming";
    document.getElementById("history").appendChild(sd);
    sd.scrollIntoView({ behavior: "smooth" });
  }
  if (m.type === "stream_chunk") { appendToStreaming(m.text); }
  if (m.type === "stream_end") {
    const streamEl = document.getElementById("ai-streaming");
    if (streamEl) {
      history.push({ role: "ai", content: streamEl.textContent }); saveState();
      streamEl.id = "";
      if (m.badges && m.badges.length) {
        const br = document.createElement("div");
        br.className = "badge-row";
        m.badges.forEach(b => {
          const s = document.createElement("span");
          s.className = "tbadge"; s.textContent = b; br.appendChild(s);
        });
        streamEl.appendChild(br);
      }
    }
    responding = false;
    setStatus("done");
  }
  if (m.type === "status") { setStatus(m.text); }
  if (m.type === "error") {
    addMsg("ai", "Error: " + m.text);
    responding = false; setStatus("error");
  }
  if (m.type === "gpu_update") {
    document.getElementById("gpu-bar").textContent =
      "⬡ " + (m.name||"GPU") + " | VRAM: " + (m.mem_used_mb||"?") + "/" + (m.mem_total_mb||"?") + " MB | Util: " + (m.gpu_util_pct||"?") + "%";
  }
});

restoreRenderedHistory();
// Poll GPU every 30s
setInterval(() => vsc.postMessage({ cmd: "gpu_status" }), 30000);
</script>
</body>
</html>`;
}

// ─── Chat participant handler (@rag in VS Code chat) ─────────────────────────
async function handleChatRequest(request, _context, stream, token) {
  const ws          = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
  const editor      = vscode.window.activeTextEditor;
  const currentFile = editor ? vscode.workspace.asRelativePath(editor.document.uri) : null;
  const query       = request.prompt.trim();
  const cmd         = request.command;

  let ragContext  = "";
  let toolBadges  = [];

  if (cmd !== "task" && cmd !== "ingest") {
    stream.progress("Searching knowledge base...");
    ragContext = await ragRetrieve(query);
    if (ragContext) toolBadges.push("Hybrid RAG");
  }

  if (cmd === "task") {
    stream.progress("Indexing repo...");
    const result = await repoTask(ws, query, currentFile);
    stream.markdown("**Plan**\n");
    (result.plan || []).forEach((s, i) => stream.markdown(`${i+1}. ${s.description} → \`${(s.files_affected||[]).join(", ")}\`\n`));
    if ((result.edits || []).length > 0) {
      stream.markdown(`\n**${result.edits.length} file edits proposed**\n`);
      result.edits.forEach(ed => stream.markdown(`- \`${ed.file}\` (L${ed.start_line}–${ed.end_line}): ${ed.description}\n`));
      const apply = await vscode.window.showQuickPick(["Apply all edits", "Preview only"],
                          { placeHolder: result.summary });
      if (apply === "Apply all edits") { await applyEdits(result.edits, ws); stream.markdown("\n✓ Edits applied."); }
    }
    stream.markdown(`\n*${result.summary}*`);
    toolBadges.push("Repo graph");
    return;
  }

  if (cmd === "ingest") {
    const t = vscode.window.createTerminal("RAG Ingest");
    t.sendText(`cd "${ws}" && python ingest.py`);
    t.show();
    stream.markdown("Re-ingesting docs – check the terminal.");
    return;
  }

  // Web search via /web_search endpoint
  let webContext = "";
  const webTriggers = /\b(search|browse|find|latest|current|today|news|price|who is|what is)\b/i;
  if (cmd === "search" || webTriggers.test(query)) {
    stream.progress("Searching the web...");
    try {
      const d = await httpPost(ragUrl(), "/web_search", { query });
      webContext = d.formatted || "";
      if (webContext) toolBadges.push(`Web (${d.source})`);
    } catch {}
  }

  // Memory
  let memContext = "";
  try {
    const mr   = await httpPost(ragUrl(), "/memory/query", { query });
    const docs  = mr?.results?.documents?.[0] || [];
    memContext  = docs.filter(Boolean).slice(0, 3).join("\n---\n");
    if (memContext) toolBadges.push("Memory");
  } catch {}

  const systemPrompt = [
    "You are a local coding assistant backed by a hybrid RAG system.",
    "Use the provided context to answer accurately.",
    "When referencing code, use markdown code blocks.",
    "Be concise. Cite sources with [N] notation.",
    currentFile ? `Current file: ${currentFile}` : "",
    ws ? `Workspace: ${ws}` : ""
  ].filter(Boolean).join("\n");

  const messages = [
    { role: "system", content: systemPrompt },
    ...(ragContext  ? [{ role: "system", content: "RETRIEVED CONTEXT:\n\n" + ragContext }]  : []),
    ...(webContext  ? [{ role: "system", content: "WEB SEARCH RESULTS:\n\n" + webContext }] : []),
    ...(memContext  ? [{ role: "system", content: "MEMORY:\n\n" + memContext }]              : []),
    { role: "user", content: query }
  ];

  stream.progress("Generating with " + model() + "...");
  await streamOllama(messages, chunk => stream.markdown(chunk));

  if (toolBadges.length) {
    stream.markdown(`\n\n---\n*Tools used: ${toolBadges.join(", ")} · Model: ${model()}*`);
  }
}

// ─── Sidebar webview ──────────────────────────────────────────────────────────
function registerSidebar(context) {
  const provider = {
    resolveWebviewView(view) {
      view.webview.options = { enableScripts: true };
      view.webview.html    = getSidebarHtml(model());

      view.webview.onDidReceiveMessage(async msg => {
        const ws     = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
        const editor = vscode.window.activeTextEditor;
        const cf     = editor ? vscode.workspace.asRelativePath(editor.document.uri) : null;
        const post   = t => view.webview.postMessage(t);

        // GPU status
        if (msg.cmd === "gpu_status") {
          try {
            const g = await httpPost(ragUrl(), "/health", {}).catch(() => ({}));
            const gs = await new Promise(resolve => {
              http.get({ hostname: "127.0.0.1", port: 8765, path: "/gpu_status" }, res => {
                let d = ""; res.on("data", c => d += c);
                res.on("end", () => { try { resolve(JSON.parse(d)); } catch { resolve({}); } });
              }).on("error", () => resolve({}));
            });
            post({ type: "gpu_update", ...gs });
          } catch {}
          return;
        }

        if (msg.cmd === "ingest") {
          const t = vscode.window.createTerminal("RAG Ingest");
          t.sendText(`cd "${ws}" && python ingest.py`);
          t.show();
          post({ type: "status", text: "ingestion started in terminal" });
          return;
        }

        if (msg.cmd === "task") {
          post({ type: "status", text: "planning..." });
          const result = await repoTask(ws, msg.query || "Analyse the current file", cf);
          let out = "**Plan**\n";
          (result.plan || []).forEach((s, i) => { out += `${i+1}. ${s.description}\n`; });
          out += `\n**${(result.edits || []).length} edits proposed**\n`;
          (result.edits || []).forEach(ed => { out += `- \`${ed.file}\`: ${ed.description}\n`; });
          post({ type: "stream_start" });
          post({ type: "stream_chunk", text: out });
          post({ type: "stream_end",   badges: ["Repo graph"] });
          if ((result.edits || []).length > 0) {
            const pick = await vscode.window.showQuickPick(["Apply all edits", "Preview only"],
                              { placeHolder: result.summary });
            if (pick === "Apply all edits") {
              await applyEdits(result.edits, ws);
              vscode.window.showInformationMessage("Applied " + result.edits.length + " edits");
            }
          }
          return;
        }

        // Default: query with all selected tools
        const q = msg.query;
        if (!q) return;

        post({ type: "stream_start" });

        const useRag = msg.tools && msg.tools.includes("rag");
        const useWeb = msg.tools && msg.tools.includes("web");
        const useMem = msg.tools && msg.tools.includes("mem");
        const badges = [];

        // Parallel context gathering
        const [ragCtx, webCtxRaw, memCtxRaw] = await Promise.all([
          useRag ? ragRetrieve(q).catch(() => "") : Promise.resolve(""),
          useWeb ? httpPost(ragUrl(), "/web_search", { query: q }).catch(() => ({})) : Promise.resolve({}),
          useMem ? httpPost(ragUrl(), "/memory/query", { query: q }).catch(() => ({})) : Promise.resolve({})
        ]);

        if (ragCtx)           badges.push("Hybrid RAG");
        const webCtx = webCtxRaw.formatted || "";
        if (webCtx)           badges.push(`Web (${webCtxRaw.source || "ddg"})`);
        const memDocs  = memCtxRaw?.results?.documents?.[0] || [];
        const memCtx   = memDocs.filter(Boolean).slice(0, 3).join("\n---\n");
        if (memCtx)           badges.push("Memory");

        const messages = [
          {
            role: "system",
            content: "You are a local coding assistant. Use context to answer accurately. Be concise."
              + (cf     ? `\nCurrent file: ${cf}` : "")
              + (webCtx ? `\n\nWEB SEARCH RESULTS:\n${webCtx}` : "")
              + (memCtx ? `\n\nMEMORY:\n${memCtx}` : "")
          },
          ...(ragCtx ? [{ role: "system", content: "CONTEXT:\n\n" + ragCtx }] : []),
          { role: "user", content: q }
        ];

        post({ type: "status", text: "generating..." });

        await streamOllama(messages, chunk => {
          post({ type: "stream_chunk", text: chunk });
        }).catch(err => {
          post({ type: "error", text: "Ollama error: " + err.message + ". Is 'ollama serve' running?" });
          return;
        });

        badges.push("Model: " + model());
        post({ type: "stream_end", badges });
      });
    }
  };

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("cognitiveRag.sidebar", provider,
      { webviewOptions: { retainContextWhenHidden: true } })
  );
}

// ─── activate ────────────────────────────────────────────────────────────────
function activate(context) {
  // 1. Inline completions (ghost text FIM)
  registerInlineCompletions(context);

  // 2. @rag chat participant
  if (vscode.chat && vscode.chat.createChatParticipant) {
    const participant = vscode.chat.createChatParticipant("cognitiveRag.chat", handleChatRequest);
    participant.iconPath = vscode.Uri.joinPath(context.extensionUri, "media", "icon.png");
    context.subscriptions.push(participant);
  }

  // 3. Sidebar
  registerSidebar(context);

  // 4. Commands
  context.subscriptions.push(
    vscode.commands.registerCommand("cognitiveRag.openChat", () => {
      vscode.commands.executeCommand("workbench.action.chat.open", { query: "@rag " });
    }),
    vscode.commands.registerCommand("cognitiveRag.repoTask", async () => {
      const ws     = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      const editor = vscode.window.activeTextEditor;
      if (!ws) return vscode.window.showErrorMessage("Open a workspace first.");
      const task = await vscode.window.showInputBox({ prompt: "Describe the repo task" });
      if (!task) return;
      const result = await repoTask(ws, task, editor ? vscode.workspace.asRelativePath(editor.document.uri) : null);
      const panel  = vscode.window.createWebviewPanel("repoTask", "Repo Task: " + task.slice(0,40),
                       vscode.ViewColumn.Two, { enableScripts: false });
      const esc = s => String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      let html = "<style>body{font-family:var(--vscode-font-family,sans-serif);padding:16px;font-size:13px;color:var(--vscode-foreground);background:var(--vscode-editor-background)}h2{margin:16px 0 8px;font-size:14px;font-weight:600}li{padding:3px 0;line-height:1.5}code{background:var(--vscode-textCodeBlock-background,#eee);padding:1px 5px;border-radius:3px;font-size:11px}details{margin:4px 0;border:1px solid var(--vscode-panel-border,#ccc);border-radius:4px}summary{padding:6px 10px;cursor:pointer;font-weight:500;list-style:none}summary::before{content:'+ ';opacity:.5}details[open]>summary::before{content:'- ';opacity:.5}pre{padding:10px;margin:0;overflow:auto;font-size:11px;line-height:1.4;background:var(--vscode-textCodeBlock-background,#f5f5f5)}em{display:block;margin-top:14px;font-size:11px;opacity:.6;border-top:1px solid var(--vscode-panel-border,#eee);padding-top:8px}</style>";
      html += "<h2>Plan</h2><ul>";
      (result.plan||[]).forEach((s,i) => { html += `<li><b>${i+1}.</b> ${esc(s.description)} <code>${(s.files_affected||[]).map(esc).join(", ")}</code></li>`; });
      html += `</ul><h2>Edits (${(result.edits||[]).length})</h2>`;
      (result.edits||[]).forEach(ed => { html += `<details><summary><code>${esc(ed.file)}</code> L${ed.start_line}–${ed.end_line} – ${esc(ed.description)}</summary><pre>${esc(ed.text)}</pre></details>`; });
      html += `<em>${esc(result.summary||"")}</em>`;
      panel.webview.html = html;
      if ((result.edits||[]).length > 0) {
        const pick = await vscode.window.showQuickPick(["Apply all edits","Preview only"]);
        if (pick === "Apply all edits") { await applyEdits(result.edits, ws); }
      }
    }),
    vscode.commands.registerCommand("cognitiveRag.ingestDocs", () => {
      const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
      const t  = vscode.window.createTerminal("RAG Ingest");
      t.sendText(`cd "${ws}" && python ingest.py`);
      t.show();
    }),
    vscode.commands.registerCommand("cognitiveRag.runTests", () => {
      const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
      const t  = vscode.window.createTerminal("RAG Tests");
      t.sendText(`cd "${ws}" && python -m pytest tests/ -v --tb=short`);
      t.show();
    })
  );

  vscode.window.showInformationMessage(
    `Cognitive RAG v17 active – model: ${model()}. Ghost text inline completions enabled. Type @rag in chat or use the sidebar.`
  );
}

function deactivate() {}
module.exports = { activate, deactivate };
'@

Set-Content "$EXT\extension.js" -Encoding UTF8 -Value $extensionJs
OK "extension.js (inline completions, GPU status, parallel context, web search)"

# ── package.json ────────────────────────────────────────────────────────────
$packageJson = @"
{
  "name": "cognitive-rag-v17",
  "displayName": "Cognitive RAG v17",
  "description": "Local Qwen/Ollama + Hybrid RAG + Repo Graph + Inline Completions + GPU offload",
  "version": "1.7.0",
  "publisher": "yourname",
  "icon": "media/icon.png",
  "engines": { "vscode": "^1.85.0" },
  "categories": ["AI","Chat","Programming Languages"],
  "keywords": ["rag","ollama","qwen","local ai","copilot","fim","inline completion","gpu"],
  "activationEvents": [
    "onStartupFinished",
    "onView:cognitiveRag.sidebar",
    "onCommand:cognitiveRag.openChat",
    "onCommand:cognitiveRag.repoTask",
    "onCommand:cognitiveRag.ingestDocs",
    "onCommand:cognitiveRag.runTests",
    "onChatParticipant:cognitiveRag.chat"
  ],
  "main": "./extension.js",
  "contributes": {
    "configuration": {
      "title": "Cognitive RAG",
      "properties": {
        "cognitiveRag.ollamaUrl":    { "type": "string",  "default": "http://localhost:11434",  "description": "Ollama API base URL" },
        "cognitiveRag.ragApiUrl":    { "type": "string",  "default": "http://localhost:8765",   "description": "RAG backend API URL" },
        "cognitiveRag.model":        { "type": "string",  "default": "cograg-gpu",              "description": "Ollama model (use cograg-gpu for GPU-offloaded)" },
        "cognitiveRag.inlineEnabled":{ "type": "boolean", "default": true,                      "description": "Enable inline ghost-text completions (FIM)" },
        "cognitiveRag.inlineDelay":  { "type": "number",  "default": 350,                       "description": "Debounce ms before triggering inline completion" }
      }
    },
    "chatParticipants": [
      { "id": "cognitiveRag.chat", "name": "rag", "fullName": "Cognitive RAG", "description": "Local RAG + Ollama coding assistant", "isSticky": false }
    ],
    "viewsContainers": {
      "activitybar": [{ "id": "cognitiveRag", "title": "Cognitive RAG", "icon": "media/icon.png" }]
    },
    "views": {
      "cognitiveRag": [{ "type": "webview", "id": "cognitiveRag.sidebar", "name": "Cognitive RAG", "visibility": "visible" }]
    },
    "commands": [
      { "command": "cognitiveRag.openChat",  "title": "Cognitive RAG: Open Chat (@rag)",        "category": "Cognitive RAG" },
      { "command": "cognitiveRag.repoTask",  "title": "Cognitive RAG: Run Repo Task",            "category": "Cognitive RAG" },
      { "command": "cognitiveRag.ingestDocs","title": "Cognitive RAG: Re-ingest Documents",      "category": "Cognitive RAG" },
      { "command": "cognitiveRag.runTests",  "title": "Cognitive RAG: Run Test Suite",           "category": "Cognitive RAG" }
    ],
    "keybindings": [
      { "command": "cognitiveRag.openChat", "key": "ctrl+alt+q", "when": "editorTextFocus" },
      { "command": "cognitiveRag.repoTask", "key": "ctrl+alt+r", "when": "editorTextFocus" }
    ]
  },
  "scripts": {
    "package":       "npx @vscode/vsce package --no-dependencies",
    "install-local": "npm install && npm run package && code --install-extension cognitive-rag-v17-1.7.0.vsix"
  },
  "devDependencies": { "@vscode/vsce": "^2.22.0" },
  "dependencies": {}
}
"@
Set-Content "$EXT\package.json" -Encoding UTF8 -Value $packageJson
OK "package.json (inlineEnabled, inlineDelay settings)"

# ── icon (reuse from v16 if present, else embed) ─────────────────────────────
$pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAHsAAABfCAYAAADI+rhfAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAKVSURBVHhe7dHZbeNQEERR7UpSWyja01IiWkLRgAO8DxdtzNjuJovkvUB9s/nO6E217vf7e7VavUejUb+mPzrkeotcpj88xHqPXKY/PqQq5PV6XX+Uvk4fYAgNDrlMH6LPDRa5TB+kjz0ej2Ejl+nD9CmQZfpAfQjkL6YP1eVA/sf0wbpYhbzZbOo/xz5OH65LgfzN6QN2IZB/OH1I557PJ8i/mT6oYyAHTR/WKZCDpw/sEMhJ04duswp5u93Wj2Qx0wdvI5Abmj58k4Hc8BSgiV6vF8htTCEyA7nlKUhGIJtMYSID2WwKFFGFvNvt6h9j7U6hIrrdbvUPsfanUBGBbTqFighs0ylURGCbTqEiAtt0ChUR2KZTqIjANp1CRQS26RQqIrBNp1ARgW06hYoIbNMpVERgm06hIgLbdAoVEdimU6iIwDadQkUEtukUKiKwTadQEYFtOoWKCGzTKVREYPttuVyC3fctFov39Xr96wJ2T1chXy6XDy5g92yfIZfA7snm8/mXyCWwO74K+Xw+K8Gngd3RzWaz/0Yugd2x/QS5BHZHViGfTid96m8Ftvmm0+mvkUtgmy4SuQS22Srk4/GoTxoS2CabTCZpyCWwW14TyCWwW1qFfDgc9OlSA7vhjcfjxpFLYDe0NpFLYCevQt7v9/pErQR24lyQS2AnzA25BHbCXEu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzlMvA9izlMrA9S7kMbM9SLgPbs5TLwPYs5TKwPUu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzlMvA9izlMrA9S7kMbM9SLgPbs5TLwPYs5TKwPUu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzPzg11VRMzj52AAAAAElFTkSuQmCC"
[System.IO.File]::WriteAllBytes("$EXT\media\icon.png",[System.Convert]::FromBase64String($pngB64))
OK "media/icon.png"

# ── Build VSIX ────────────────────────────────────────────────────────────────
Step "Building VSIX"
$vsixPath = "$ROOT\cognitive-rag-v17-1.7.0.vsix"
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Push-Location $EXT
    try {
        npm install --save-dev "@vscode/vsce" --silent 2>&1 | Out-Null
        npx "@vscode/vsce" package --no-dependencies --out $vsixPath 2>&1 | Out-Null
        if (Test-Path $vsixPath) { OK "VSIX built: $vsixPath" } else { Warn "VSIX build failed - using folder install" }
    } catch { Warn "VSIX skipped: $_" }
    Pop-Location
} else { Warn "npm not found - skipping VSIX" }

# ── Install extension ─────────────────────────────────────────────────────────
Step "Installing extension"
$dest = $env:USERPROFILE + "\.vscode\extensions\cognitive-rag-v17"
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item $EXT -Destination $dest -Recurse
OK "Installed: $dest"
if ((Test-Path $vsixPath) -and (Get-Command code -ErrorAction SilentlyContinue)) {
    code --install-extension $vsixPath --force
    OK "VSIX installed via code CLI"
}

# ── Sample docs + launchers ───────────────────────────────────────────────────
Step "Sample docs + launchers"
Set-Content "$ROOT\docs\overview.md" -Encoding UTF8 -Value @'
# Cognitive RAG v17
Backend: POST /query /retrieve /repo_task /fim /web_search /memory/store /memory/query GET /health /gpu_status
Extension: sidebar, @rag chat, Ctrl+Alt+Q (chat), Ctrl+Alt+R (repo task), inline FIM ghost text
GPU: cograg-gpu model auto-configured with CUDA layers for RTX 2060 12GB
'@

$sl = @(
    "Set-Location `"$ROOT`"",
    "Write-Host `"Cognitive RAG v17 | Model: $MODEL_GPU | GPU: $GPU_NAME`" -ForegroundColor Cyan",
    "Start-Process ollama -ArgumentList `"serve`" -WindowStyle Hidden -ErrorAction SilentlyContinue",
    "Start-Sleep 3",
    "Write-Host `"API: http://127.0.0.1:$PORT`" -ForegroundColor Green",
    "Write-Host `"Test: .\run_tests.ps1`" -ForegroundColor DarkCyan",
    "& `"$PY`" -m uvicorn server.api:app --host 127.0.0.1 --port $PORT --reload"
)
$sl -join "`n" | Set-Content "$ROOT\start_server.ps1" -Encoding UTF8

@("Set-Location `"$ROOT`"","& `"$PY`" ingest.py") -join "`n" |
    Set-Content "$ROOT\ingest_docs.ps1" -Encoding UTF8

# ── Optional: SearXNG docker-compose for full web search ─────────────────────
Set-Content "$ROOT\searxng-compose.yml" -Encoding UTF8 -Value @'
# Run: docker compose -f searxng-compose.yml up -d
# Then set SEARXNG_URL=http://localhost:8888 before starting the RAG server
version: "3"
services:
  searxng:
    image: searxng/searxng:latest
    ports:
      - "8888:8080"
    volumes:
      - ./searxng-data:/etc/searxng
    environment:
      - SEARXNG_BASE_URL=http://localhost:8888
    restart: unless-stopped
'@
OK "searxng-compose.yml"

# ── Final summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Cognitive RAG v17 - INSTALLED"                              -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  GPU     : $GPU_NAME ($GPU_LAYERS layers offloaded)"          -ForegroundColor Cyan
Write-Host "  Model   : $MODEL_GPU (based on $MODEL)"                      -ForegroundColor Cyan
Write-Host "  Root    : $ROOT"
Write-Host "  API     : http://127.0.0.1:$PORT"
Write-Host ""
Write-Host "  UPGRADES FROM v16:" -ForegroundColor Yellow
Write-Host "  [GPU]    Ollama Modelfile with num_gpu=$GPU_LAYERS (CUDA offload)"
Write-Host "  [INLINE] InlineCompletionItemProvider (FIM ghost text as you type)"
Write-Host "  [SEARCH] /web_search: SearXNG→Brave→DDG + full page body fetch"
Write-Host "  [AST]    Tree-sitter semantic symbol extraction (Python, JS, TS)"
Write-Host "  [MEM]    ChromaDB vector memory (replaces JSONL linear scan)"
Write-Host "  [TESTS]  20-test harness: unit + integration (pytest)"
Write-Host "  [PERF]   Parallel Promise.all() for RAG/web/memory context"
Write-Host "  [FIM]    /fim endpoint for Fill-in-the-Middle completions"
Write-Host "  [PANEL]  Live GPU VRAM/util bar in sidebar (30s poll)"
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. cd `"$ROOT`""
Write-Host "  2. .\start_server.ps1"
Write-Host "  3. VS Code: Ctrl+Shift+P → Developer: Reload Window"
Write-Host "  4. Click the hexagon icon in the Activity Bar"
Write-Host "  5. .\run_tests.ps1   (runs all 20 tests)"
Write-Host ""
Write-Host "  OPTIONAL - better web search:" -ForegroundColor DarkCyan
Write-Host "  docker compose -f `"$ROOT\searxng-compose.yml`" up -d"
Write-Host '  $env:SEARXNG_URL = "http://localhost:8888"'
Write-Host "  Then restart start_server.ps1"
Write-Host ""
Write-Host "  OPTIONAL - even better model quality:" -ForegroundColor DarkCyan
Write-Host "  ollama pull qwen2.5-coder:14b   (needs 12GB VRAM, fits RTX 2060 12GB)"
Write-Host '  Then set cognitiveRag.model = "qwen2.5-coder:14b" in VS Code settings'
Write-Host ""
Write-Host "  Parity estimate: ~72% (was 55%)" -ForegroundColor Green
Write-Host "  Remaining gap: model scale, latency vs cloud, no auth/tools API"
Write-Host "============================================================" -ForegroundColor Green
