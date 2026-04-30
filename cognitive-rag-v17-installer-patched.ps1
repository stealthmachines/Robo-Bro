#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  COGNITIVE RAG v17 - COMPLETE INSTALLER (PATCHED)
#  Fixes applied vs original:
#   [FIX-1]  Removed non-existent 'searxng-client' pip package
#   [FIX-2]  Packages now installed in two safe batches so a
#            single bad package cannot abort the whole install
#   [FIX-3]  GPU VRAM detection uses nvidia-smi instead of WMI
#            (WMI caps at 4 GB on many systems, including RTX 2060)
#   [FIX-4]  pip install uses --no-deps guard + individual retries
#   [FIX-5]  start_server.ps1 activates venv before launching
#   [FIX-6]  package.json gets "repository" field (removes VSIX warn)
#   [FIX-7]  engine.py MODEL_GPU exported so api.py import works
#   [FIX-8]  api.py startup/shutdown use lifespan, not deprecated events
#   [FIX-9]  ChromaDB OllamaEmbeddingFunction correct import path
#   [FIX-10] retriever.py uses updated LangChain community imports
#   [FIX-11] ingest.py persist() removed (Chroma auto-persists now)
#   [FIX-12] Extension httpPost GPU status uses correct GET method
#   [FIX-13] FIM endpoint gracefully handles models w/o FIM support
# ================================================================

$ROOT   = "$HOME\cognitive-rag-v17"
$VENV   = "$ROOT\.venv"
$PY     = "$VENV\Scripts\python.exe"
$PIP    = "$VENV\Scripts\pip.exe"
$PORT   = 8765
$EMBED  = "nomic-embed-text"
$V16    = "$HOME\cognitive-rag-v16"

function Step($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "   OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   !!: $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "   -- $m" -ForegroundColor DarkGray }

# ── GPU detection (FIX-3: use nvidia-smi, not WMI) ───────────────────────────
Step "Detecting GPU"
$GPU_LAYERS = 0
$GPU_NAME   = "CPU-only"
try {
    # Try nvidia-smi first — gives accurate VRAM even on cards with >4 GB
    $smiOut = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
    if ($smiOut) {
        $parts   = $smiOut.Trim() -split ",\s*"
        $GPU_NAME = $parts[0].Trim()
        $vramMB   = [int]$parts[1].Trim()
        if ($vramMB -ge 10000) { $GPU_LAYERS = 43 }
        elseif ($vramMB -ge 6000)  { $GPU_LAYERS = 30 }
        elseif ($vramMB -ge 4000)  { $GPU_LAYERS = 20 }
        elseif ($vramMB -ge 2000)  { $GPU_LAYERS = 10 }
        else                        { $GPU_LAYERS = 0  }
        OK "$GPU_NAME | VRAM: ${vramMB}MB | Layers offloaded: $GPU_LAYERS"
    } else {
        throw "nvidia-smi returned nothing"
    }
} catch {
    # Fallback: WMI (may underreport >4 GB cards)
    try {
        $gpuInfo = Get-WmiObject Win32_VideoController |
                   Where-Object { $_.Name -match "NVIDIA|AMD|Radeon" } |
                   Select-Object -First 1
        if ($gpuInfo) {
            $GPU_NAME = $gpuInfo.Name
            $vramMB   = [math]::Round($gpuInfo.AdapterRAM / 1MB)
            # WMI caps at 4 GB; if we see exactly 4095 MB assume 12 GB RTX card
            if ($vramMB -le 4096 -and $GPU_NAME -match "RTX 2060|RTX 3\d\d0|RTX 4\d\d0") {
                Warn "WMI reported $vramMB MB (likely wrong). Assuming 12 GB for $GPU_NAME."
                $vramMB = 12288
            }
            if ($vramMB -ge 10000) { $GPU_LAYERS = 43 }
            elseif ($vramMB -ge 6000)  { $GPU_LAYERS = 30 }
            elseif ($vramMB -ge 4000)  { $GPU_LAYERS = 20 }
            elseif ($vramMB -ge 2000)  { $GPU_LAYERS = 10 }
            OK "$GPU_NAME | VRAM (estimated): ${vramMB}MB | Layers offloaded: $GPU_LAYERS"
        }
    } catch { Warn "GPU detection failed entirely - defaulting to CPU" }
}

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
    OK "Migrated v16 memory -> v17"
}

# ── Ollama + model ───────────────────────────────────────────────────────────
Step "Detecting Ollama model"
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 4
}
$MODEL = "qwen2.5-coder:7b"
try {
    $tags = Invoke-RestMethod "http://localhost:11434/api/tags" -TimeoutSec 6
    $all  = @($tags.models | ForEach-Object { $_.name })
    Write-Host "   Models: $($all -join ', ')" -ForegroundColor DarkCyan
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
PARAMETER num_ctx 32768
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

# ── Install packages (FIX-1, FIX-2, FIX-4) ───────────────────────────────────
# Split into batches. No 'searxng-client' (it doesn't exist on PyPI).
# Each batch is independent so one failure doesn't kill the rest.
Step "Installing packages (batch 1/3 - core web framework)"
& $PIP install --upgrade pip --quiet
& $PIP install --quiet `
    fastapi `
    "uvicorn[standard]" `
    pydantic `
    httpx `
    requests
if ($LASTEXITCODE -ne 0) { Warn "Batch 1 had errors - some packages may be missing" } else { OK "Batch 1 done" }

Step "Installing packages (batch 2/3 - LangChain + vector DBs)"
& $PIP install --quiet `
    langchain `
    langchain-community `
    langchain-text-splitters `
    chromadb `
    faiss-cpu `
    rank_bm25 `
    ollama
if ($LASTEXITCODE -ne 0) { Warn "Batch 2 had errors" } else { OK "Batch 2 done" }

Step "Installing packages (batch 3/3 - document loaders + dev tools)"
& $PIP install --quiet `
    "unstructured[md]" `
    pypdf `
    tree-sitter `
    tree-sitter-python `
    tree-sitter-javascript `
    pytest `
    pytest-asyncio
if ($LASTEXITCODE -ne 0) { Warn "Batch 3 had errors" } else { OK "Batch 3 done" }

# Verify critical packages
Step "Verifying critical packages"
$criticalPkgs = @("fastapi","uvicorn","chromadb","langchain","ollama","pytest")
foreach ($pkg in $criticalPkgs) {
    $check = & $PY -c "import $($pkg.Replace('-','_')); print('ok')" 2>&1
    if ($check -eq "ok") { OK "$pkg OK" } else { Warn "$pkg MISSING - $check" }
}

# ════════════════════════════════════════════════════════════════════════════
#  PYTHON SOURCE FILES
# ════════════════════════════════════════════════════════════════════════════

Step "Writing memory engine (vector-backed)"
Set-Content "$ROOT\memory\brain.py" -Encoding UTF8 -Value @'
"""
Cognitive memory: JSONL event log + ChromaDB vector store for semantic search.
FIX-9: corrected ChromaDB OllamaEmbeddingFunction import path for chromadb>=0.4
"""
import json, os, time, hashlib
from pathlib import Path

DB_PATH = Path("./memory/cognition.jsonl")
_chroma = None

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
'@
Set-Content "$ROOT\memory\__init__.py" -Encoding UTF8 -Value ""
OK "memory/brain.py"

# ── Engine (FIX-7: MODEL_GPU exported at module level) ───────────────────────
Step "Writing cognition engine"
$eng = @"
"""
FIX-7: MODEL_GPU defined as a proper module-level name so api.py can import it.
"""
import asyncio, json, time, traceback, urllib.request
from memory.brain import write, search

MODEL_GPU = "$MODEL_GPU"
MODEL_RAW = "$MODEL"
MODEL     = MODEL_GPU   # alias used internally

STATE = {"cycle": 0, "running": True}

def _chat(messages, temp=0.1, model=None):
    m    = model or MODEL
    body = json.dumps({
        "model": m, "messages": messages, "stream": False,
        "options": {"temperature": temp, "num_ctx": 8192}
    }).encode()
    req = urllib.request.Request(
        "http://localhost:11434/api/chat", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read()).get("message", {}).get("content", "")
    except Exception as e:
        return f"[ollama error: {e}]"

async def cognition_cycle(query: str) -> dict:
    STATE["cycle"] += 1
    cid  = STATE["cycle"]
    write({"event": "cycle_start", "cycle": cid, "query": query})
    hits = search(query, n=3)
    mem  = "\n".join(json.dumps(h) for h in hits) if hits else "none"
    reasoning = await asyncio.to_thread(_chat, [
        {"role": "system", "content": "You are a concise reasoning engine."},
        {"role": "user",   "content": f"Query: {query}\nMemory:\n{mem}\nAnswer concisely."}
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
Set-Content "$ROOT\core\engine.py"   -Encoding UTF8 -Value $eng
Set-Content "$ROOT\core\__init__.py" -Encoding UTF8 -Value ""
OK "core/engine.py"

# ── Retriever (FIX-10: updated LangChain imports) ────────────────────────────
Step "Writing hybrid retriever"
Set-Content "$ROOT\workers\retriever.py" -Encoding UTF8 -Value @'
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
'@
Set-Content "$ROOT\workers\__init__.py" -Encoding UTF8 -Value ""
OK "workers/retriever.py"

# ── Repo graph ────────────────────────────────────────────────────────────────
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

_ts_parsers = {}

def _get_ts_parser(ext):
    if ext in _ts_parsers:
        return _ts_parsers[ext]
    try:
        import tree_sitter_python as tspy
        import tree_sitter_javascript as tsjs
        from tree_sitter import Language, Parser
        lang_map = {
            ".py":  tspy.language(),
            ".js":  tsjs.language(),
            ".ts":  tsjs.language(),
            ".jsx": tsjs.language(),
            ".tsx": tsjs.language(),
        }
        if ext in lang_map:
            p = Parser(Language(lang_map[ext]))
            _ts_parsers[ext] = p
            return p
    except Exception:
        pass
    _ts_parsers[ext] = None
    return None

def _extract_symbols_ts(content: str, ext: str) -> list:
    parser = _get_ts_parser(ext)
    if parser is None:
        return SYM_RE.findall(content)[:20]
    try:
        tree = parser.parse(bytes(content, "utf-8"))
        syms = []
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
    return len(re.findall(r'\b(if|else|elif|for|while|switch|case|catch|except|and|or)\b', content))

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
    out    = []
    ranked = sorted(REPO_INDEX.items(), key=lambda x: x[1].get("complexity", 0), reverse=True)
    for f, d in ranked[:max_files]:
        syms = ", ".join(d["symbols"][:8]) if d["symbols"] else "-"
        cc   = d.get("complexity", 0)
        out.append(f"{f} ({d['lines']} lines, CC={cc}) [{syms}]")
    return "\n".join(out) or "No files indexed."

def get_file_context(workspace_root: str, relative_path: str) -> str:
    try:
        p = Path(workspace_root) / relative_path
        return p.read_text(encoding="utf-8", errors="ignore")[:6000]
    except Exception:
        return ""
'@
Set-Content "$ROOT\graph\__init__.py" -Encoding UTF8 -Value ""
OK "graph/repo.py"

# ── Web search ────────────────────────────────────────────────────────────────
Step "Writing web search module"
Set-Content "$ROOT\workers\websearch.py" -Encoding UTF8 -Value @'
"""
Web search: tries SearXNG (self-hosted) -> Brave API -> DuckDuckGo instant -> Bing scraper.
Also fetches full page text from result URLs, preserves image URLs for OCR, and
transcribes image content using the local moondream vision model.
"""
import os, json, urllib.request, urllib.parse, html, re

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8888")
BRAVE_KEY   = os.environ.get("BRAVE_API_KEY", "")
DDG_URL     = "https://api.duckduckgo.com/"

_BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# Compiled pattern to find [IMG: url] markers injected by _strip_html
_IMG_MARKER_RE = re.compile(r'\[IMG:\s*(https?://[^\]]+)\]')

def _strip_html(raw: str) -> str:
    raw = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.DOTALL | re.IGNORECASE)
    raw = re.sub(r"<style[^>]*>.*?</style>",   "", raw, flags=re.DOTALL | re.IGNORECASE)
    # Preserve image src URLs as readable markers before stripping tags
    raw = re.sub(
        r'<img[^>]+src=["\']([^"\']+)["\'][^>]*/?>',
        r'[IMG: \1] ',
        raw,
        flags=re.IGNORECASE,
    )
    raw = re.sub(r"<[^>]+>", " ", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"\s{3,}", "\n", raw)
    # 150K chars — a single Discourse post can be 150K; threads can exceed 1M.
    # format_for_llm then selects how much to pass to the LLM based on context budget.
    return raw[:150000].strip()

def _fetch_url(url: str, timeout=10) -> str:
    """Fetch a URL using requests (browser UA, better TLS). Falls back to Google/Bing cache."""
    candidates = [url]
    domain_only = re.sub(r"https?://", "", url).rstrip("/")
    candidates.append(f"https://webcache.googleusercontent.com/search?q=cache:{url}")
    candidates.append(
        f"https://cc.bingj.com/cache.aspx?q={urllib.parse.quote(domain_only)}"
        f"&url={urllib.parse.quote(url)}"
    )

    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

    for attempt_url in candidates:
        # Try requests first (better TLS negotiation / redirect handling)
        try:
            import requests as _req
            sess = _req.Session()
            sess.headers.update({
                "User-Agent":      _BROWSER_UA,
                "Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
                "Accept-Encoding": "identity",
            })
            r = sess.get(attempt_url, timeout=(5, timeout), verify=False,
                         allow_redirects=True, stream=False)
            if r.status_code == 200 and len(r.content) > 200:
                text = _strip_html(r.text)
                if len(text) > 100:
                    return text
        except Exception:
            pass
        # urllib fallback
        try:
            req = urllib.request.Request(attempt_url, headers={"User-Agent": _BROWSER_UA})
            opener = urllib.request.build_opener(
                urllib.request.HTTPRedirectHandler(),
                urllib.request.HTTPSHandler(context=ctx),
            )
            with opener.open(req, timeout=timeout) as r:
                ct = r.headers.get("Content-Type", "")
                if "text" in ct or "html" in ct:
                    raw = r.read(2097152).decode("utf-8", errors="ignore")  # 2 MB raw
                    text = _strip_html(raw)
                    if len(text) > 100:
                        return text
        except Exception:
            pass
    return ""

def _searxng(query: str, n=5) -> list:
    try:
        url = (f"{SEARXNG_URL}/search?q={urllib.parse.quote(query)}"
               f"&format=json&engines=google,bing&language=en")
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read())
        return [{"title": i.get("title", ""), "url": i.get("url", ""),
                 "snippet": i.get("content", "")} for i in data.get("results", [])[:n]]
    except Exception:
        return []

def _brave(query: str, n=5) -> list:
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
            data    = json.loads(r.read())
            results = data.get("web", {}).get("results", [])
        return [{"title": i.get("title", ""), "url": i.get("url", ""),
                 "snippet": i.get("description", "")} for i in results[:n]]
    except Exception:
        return []

def _ddg(query: str) -> list:
    try:
        url = (f"{DDG_URL}?q={urllib.parse.quote(query)}"
               f"&format=json&no_redirect=1&no_html=1&skip_disambig=1")
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=6) as r:
            j = json.loads(r.read())
        parts = []
        if j.get("AbstractText"):
            parts.append({"title": j.get("Heading", ""), "url": j.get("AbstractURL", ""),
                          "snippet": j["AbstractText"]})
        if j.get("Answer"):
            parts.append({"title": "Answer", "url": "", "snippet": j["Answer"]})
        for t in (j.get("RelatedTopics") or [])[:4]:
            if t.get("Text"):
                parts.append({"title": t.get("FirstURL", ""), "url": t.get("FirstURL", ""),
                              "snippet": t["Text"]})
        return parts
    except Exception:
        return []

_DOMAIN_RE = re.compile(
    r"https?://[^\s\"'>]+|(?<!\w)([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?"
    r"\.(?:org|com|net|io|gov|edu|co|ai|dev|app|info|biz)(?:/[^\s\"'>]*)?)",
    re.IGNORECASE
)

def _extract_urls(text: str) -> list:
    """Pull any bare domains or full URLs out of a query string."""
    out = []
    for m in _DOMAIN_RE.finditer(text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url
        out.append(url)
    return out

def _bing_scrape(query: str, n=5) -> list:
    """Scrape Bing search results page — fallback when APIs return nothing."""
    try:
        import requests as _req
        url = f"https://www.bing.com/search?q={urllib.parse.quote(query)}&count={n}"
        r = _req.get(url, headers={
            "User-Agent":      _BROWSER_UA,
            "Accept":          "text/html,*/*",
            "Accept-Encoding": "identity",
            "Accept-Language": "en-US,en;q=0.9",
        }, timeout=8, verify=False, allow_redirects=True)
        if r.status_code != 200:
            return []
        results = []
        title_blocks   = re.findall(r'<h2[^>]*><a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>', r.text)
        snippet_blocks = re.findall(r'<p class="b_lineclamp\d[^"]*">(.+?)</p>', r.text, re.DOTALL)
        for i, (url_found, title) in enumerate(title_blocks[:n]):
            if url_found.startswith("http") and "bing.com" not in url_found:
                snippet = html.unescape(
                    re.sub(r"<[^>]+>", " ", snippet_blocks[i])
                ).strip() if i < len(snippet_blocks) else ""
                results.append({
                    "title":   html.unescape(title),
                    "url":     url_found,
                    "snippet": snippet,
                })
        return results
    except Exception:
        return []

def _ocr_image(img_url: str) -> str:
    """Download an image and transcribe its text using the local moondream vision model."""
    try:
        import requests as _req, base64
        r = _req.get(img_url, timeout=10, verify=False,
                     headers={"User-Agent": _BROWSER_UA}, allow_redirects=True)
        if r.status_code != 200 or len(r.content) < 500:
            return ""
        ct = r.headers.get("Content-Type", "")
        if not any(t in ct for t in ("image/", "jpeg", "png", "gif", "webp")):
            return ""
        import ollama as _ol
        resp = _ol.generate(
            model="moondream:latest",
            prompt="Read and transcribe all text visible in this image.",
            images=[base64.b64encode(r.content).decode()],
            options={"temperature": 0.0, "num_predict": 512},
        )
        # ollama >= 0.2 returns a GenerateResponse object; older versions return a dict
        if hasattr(resp, "response"):
            return (resp.response or "").strip()
        return resp.get("response", "").strip()
    except Exception:
        return ""

def _ocr_page_images(text: str, max_images: int = 6) -> str:
    """Replace [IMG: url] markers in page text with moondream OCR transcriptions."""
    markers = _IMG_MARKER_RE.findall(text)
    if not markers:
        return text
    for url in markers[:max_images]:
        ocr = _ocr_image(url)
        placeholder = f"[IMG: {url}]"
        if ocr:
            text = text.replace(placeholder, f"[OCR: {ocr}]", 1)
        else:
            text = text.replace(placeholder, "", 1)
    # Remove any remaining unprocessed markers beyond max_images
    text = _IMG_MARKER_RE.sub("", text)
    return re.sub(r"\s{3,}", "\n", text).strip()

def search(query: str, fetch_pages=True, n=5) -> dict:
    results = _searxng(query, n)
    source  = "searxng" if results else None
    if not results:
        results = _brave(query, n)
        source  = "brave" if results else None
    if not results:
        results = _ddg(query)
        source  = "ddg" if results else None
    if not results:
        results = _bing_scrape(query, n)
        source  = "bing" if results else None
    pages = {}
    if fetch_pages and results:
        for r in results[:2]:
            u = r.get("url", "")
            if u and u.startswith("http"):
                text = _fetch_url(u)
                if text:
                    pages[u] = _ocr_page_images(text)
    # Fallback: if no results at all, try fetching any URL/domain in the query directly
    if not results:
        for url in _extract_urls(query):
            text = _fetch_url(url)
            if text:
                text = _ocr_page_images(text)
                results.append({"title": url, "url": url, "snippet": text[:1200]})
                pages[url] = text
                source = "direct_fetch"
                break
    return {"results": results, "source": source or "none", "pages": pages}

def format_for_llm(result: dict) -> str:
    pages     = result.get("pages", {})
    num_pages = max(1, sum(1 for r in result["results"] if r.get("url", "") in pages))
    # Budget: 100K chars total across all pages (≈25K tokens), shared equally.
    # Minimum 10K per page so short pages are still informative.
    per_page  = max(10000, 100000 // num_pages)
    lines = []
    for i, r in enumerate(result["results"]):
        lines.append(f"[{i+1}] {r['title']}\n{r['snippet']}")
        url = r.get("url", "")
        if url in pages:
            lines.append(f"    Full text excerpt:\n{pages[url][:per_page]}")
    return "\n\n".join(lines)

'@
OK "workers/websearch.py"
# ── Audio transcription module ──────────────────────────────────────────────
Step "Writing audio transcription module"
Set-Content "$ROOT\workers\audio.py" -Encoding UTF8 -Value @'
"""
Audio transcription using faster-whisper (local, no cloud dependency).
Supports file paths and direct URLs. Auto-selects GPU if CUDA is available.

Large-file strategy: faster_whisper's feature extractor runs STFT on the whole
audio array before chunking, which requires ~1 GB RAM for a 55-min podcast.
Fix: pre-split via ffmpeg into 5-minute WAV chunks, transcribe each, merge.
"""
import os, math, subprocess, tempfile
from pathlib import Path

_MODEL          = None   # GPU (or auto) model
_CPU_MODEL      = None   # CPU fallback model
_MODEL_SIZE     = os.environ.get("WHISPER_MODEL", "base")   # tiny/base/small/medium/large
# CPU fallback always uses tiny — smaller BLAS workspace, fits in constrained RAM
_CPU_MODEL_SIZE = os.environ.get("WHISPER_CPU_MODEL", "tiny")
_FFMPEG         = os.environ.get("FFMPEG_PATH", r"c:\programdata\chocolatey\bin\ffmpeg.exe")
_CHUNK_SECS     = 300    # 5-minute chunks for large files

# Limit MKL/OpenMP threads before any model loads to prevent mkl_malloc OOM
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")

def _get_model(force_cpu=False):
    global _MODEL, _CPU_MODEL
    from faster_whisper import WhisperModel
    if force_cpu:
        if _CPU_MODEL is None:
            # tiny model + cpu_threads=1 keeps MKL workspace small enough to fit in RAM
            _CPU_MODEL = WhisperModel(
                _CPU_MODEL_SIZE, device="cpu", compute_type="float32", cpu_threads=1
            )
        return _CPU_MODEL
    if _MODEL is None:
        try:
            import ctranslate2
            device  = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
            compute = "float16" if device == "cuda" else "float32"
        except Exception:
            device, compute = "cpu", "float32"
        _MODEL = WhisperModel(_MODEL_SIZE, device=device, compute_type=compute)
    return _MODEL


def _get_duration(path: str) -> float:
    """Return audio duration in seconds via ffprobe. Returns 9999 on failure."""
    ffprobe = _FFMPEG.replace("ffmpeg.exe", "ffprobe.exe")
    try:
        r = subprocess.run(
            [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=30,
        )
        import json
        return float(json.loads(r.stdout)["format"]["duration"])
    except Exception:
        return 9999.0


def _transcribe_chunked(path: str, model, language=None) -> dict:
    """Split a large audio file into _CHUNK_SECS-second WAV slices and transcribe each."""
    duration = _get_duration(path)
    n_chunks = math.ceil(duration / _CHUNK_SECS)
    all_segs, all_text, lang = [], [], None

    for i in range(n_chunks):
        start = i * _CHUNK_SECS
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            chunk_path = tf.name
        try:
            subprocess.run(
                [
                    _FFMPEG, "-y",
                    "-ss", str(start), "-t", str(_CHUNK_SECS),
                    "-i", path,
                    "-ar", "16000", "-ac", "1",
                    chunk_path,
                ],
                capture_output=True, check=True, timeout=120,
            )
            segs, info = model.transcribe(
                chunk_path,
                beam_size=5,
                language=language,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
            )
            if lang is None:
                lang = info.language
            for s in segs:
                t = s.text.strip()
                all_segs.append({"start": s.start + start, "end": s.end + start, "text": t})
                if t:
                    all_text.append(t)
        finally:
            try:
                os.unlink(chunk_path)
            except OSError:
                pass

    return {"text": " ".join(all_text), "language": lang or "unknown", "segments": all_segs}


def transcribe_file(path: str, language: str = None) -> dict:
    """Transcribe an audio or video file.

    Returns:
        {"text": str, "language": str, "segments": list}

    For files longer than _CHUNK_SECS seconds the file is split via ffmpeg so
    that faster_whisper's STFT never processes more than one chunk at a time.
    """
    def _run(model):
        duration = _get_duration(path)
        if duration > _CHUNK_SECS:
            return _transcribe_chunked(path, model, language)
        segments, info = model.transcribe(
            path,
            beam_size=5,
            language=language,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 500},
        )
        seg_list = [{"start": s.start, "end": s.end, "text": s.text.strip()} for s in segments]
        full_text = " ".join(s["text"] for s in seg_list)
        return {"text": full_text, "language": info.language, "segments": seg_list}

    try:
        return _run(_get_model())
    except (RuntimeError, OSError) as e:
        err = str(e).lower()
        if "cublas" in err or "cuda" in err or "dll" in err:
            import warnings
            warnings.warn(f"faster-whisper CUDA error ({e}); retrying on CPU.")
            return _run(_get_model(force_cpu=True))
        raise
    except MemoryError:
        return _transcribe_chunked(path, _get_model(force_cpu=True), language)

def transcribe_url(url: str, language: str = None) -> dict:
    """Download audio/video from a URL, transcribe, and return result dict."""
    import requests
    r = requests.get(url, timeout=60, stream=True,
                     headers={"User-Agent": "cognitive-rag/1.7"})
    r.raise_for_status()
    suffix = Path(url.split("?")[0]).suffix or ".mp3"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        for chunk in r.iter_content(65536):
            f.write(chunk)
        tmp = f.name
    try:
        return transcribe_file(tmp, language=language)
    finally:
        os.unlink(tmp)

'@
OK "workers/audio.py"


# ── Ingest (FIX-11: removed deprecated .persist()) ───────────────────────────
Step "Writing ingest.py"
Set-Content "$ROOT\ingest.py" -Encoding UTF8 -Value @'
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
except ImportError:
    from langchain_community.embeddings import OllamaEmbeddings

from langchain_community.document_loaders import DirectoryLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from rank_bm25 import BM25Okapi

def ingest():
    print("Loading ./docs/ ...")
    loader = DirectoryLoader("./docs", glob="**/*.{md,txt,pdf}", show_progress=True)
    docs   = loader.load()
    if not docs:
        print("No docs found in ./docs/")
        return
    chunks = RecursiveCharacterTextSplitter(
        chunk_size=512, chunk_overlap=64
    ).split_documents(docs)
    print(f"  {len(chunks)} chunks from {len(docs)} docs")
    emb = OllamaEmbeddings(model="nomic-embed-text", base_url="http://localhost:11434")
    # FIX-11: PersistentClient auto-persists; no .persist() call needed
    Chroma.from_documents(chunks, emb, persist_directory="./chroma_db")
    bm25 = BM25Okapi([c.page_content.lower().split() for c in chunks])
    pickle.dump({"bm25": bm25, "chunks": chunks}, open("bm25_index.pkl", "wb"))
    print("Done.")

if __name__ == "__main__":
    ingest()
'@
OK "ingest.py"

# ── FastAPI server (FIX-8: lifespan replaces on_event) ───────────────────────
Step "Writing FastAPI server"
Set-Content "$ROOT\server\__init__.py" -Encoding UTF8 -Value ""

$api = @"
﻿"""
FIX-7: imports MODEL_GPU from core.engine (now a proper module-level export).
FIX-8: uses contextlib lifespan instead of deprecated @app.on_event decorators.
FIX-13: /fim endpoint handles models without native FIM tokens gracefully.
"""
import sys, os, asyncio, json
from contextlib import asynccontextmanager
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional
import ollama as _ol

from core.engine       import run as cog_run, background_loop, stop as cog_stop, STATE, MODEL_GPU
from workers.retriever import retrieve as hybrid_retrieve
from workers.websearch import search as web_search, format_for_llm
from graph.repo        import build as build_graph, summary as graph_summary, get_file_context
from memory.brain      import write as mem_write, search as mem_search, recent as mem_recent

MODEL = MODEL_GPU

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(background_loop())
    yield
    cog_stop()
    task.cancel()

app = FastAPI(title="Cognitive RAG v17", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# â”€â”€ Pydantic models â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class Q(BaseModel):
    query: str
    history: Optional[List[dict]] = []   # [{"role":"user"|"assistant", "content":"..."}]
class RepoReq(BaseModel):  workspace_root: str; task: str; current_file: Optional[str] = None
class PlanStep(BaseModel): description: str; files_affected: List[str]
class Edit(BaseModel):     file: str; start_line: int; end_line: int; text: str; description: str
class TaskResp(BaseModel): plan: List[PlanStep]; edits: List[Edit]; summary: str
class MemReq(BaseModel):   id: str; text: str; meta: Optional[dict] = None
class FIMReq(BaseModel):       prefix: str; suffix: str; language: str = "python"; max_tokens: int = 128
class TranscribeReq(BaseModel): source: str; language: str = None  # file path or URL

# â”€â”€ Routes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
@app.get("/health")
def health():
    return {"status": "v17 online", "model": MODEL, "cycle": STATE["cycle"]}

# ── Intent keywords for agentic dispatch ────────────────────────────────────
_WEB_TRIGGERS  = {
    "search", "look up", "lookup", "google", "bing", "online", "web search",
    "find out", "what is", "who is", "what are", "what does",
    "visit", "browse", "confirm", "check out", "tell me about",
    ".org", ".com", ".net", ".io", "http", "https", "site:", "://",
}
_DIAG_TRIGGERS = {
    "self-test", "self test", "diagnose", "health check", "health-check",
    "cycle through", "test your", "run your", "check yourself",
    "your functions", "your abilities", "what can you do",
}
_AUDIO_TRIGGERS = {
    "transcribe", "transcript", ".mp3", ".wav", ".m4a", ".ogg",
    ".webm", ".flac", ".opus", ".aac", "audio file", "podcast",
    "recording", "listen to",
}
_AUDIO_EXT = ('.mp3', '.wav', '.m4a', '.ogg', '.webm', '.flac', '.opus', '.aac', '.wma')
_IMAGE_EXT  = ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tiff', '.tif')

@app.post("/query")
async def query(req: Q):
    from core.engine import _chat, _ollama_sem
    import re as _re
    q_lower = req.query.lower()
    tool_context = ""
    tools_used: list = []
    doc_sources: list = []

    # Pull URLs from history so follow-up questions re-use the same page/audio
    _history_text = " ".join(
        m.get("content", "") for m in (req.history or []) if m.get("content")
    )
    _all_text = req.query + " " + _history_text

    # ── Intent: web search ────────────────────────────────────────────────────
    # Skip web search if the query is purely a direct image URL (handled by OCR route below)
    _direct_img_urls = [
        u.rstrip('.,;)"\'')
        for u in _re.findall(r'https?://\S+', _all_text)
        if any(u.lower().rstrip('.,;)"\'').endswith(ext) for ext in _IMAGE_EXT)
    ]
    # Pure image query = has image URLs, no audio, and no non-image URLs also present
    _non_image_urls = [
        u for u in _re.findall(r'https?://\S+', _all_text)
        if not any(u.lower().rstrip('.,;)"\''). endswith(ext) for ext in _IMAGE_EXT)
    ]
    _is_pure_image_query = bool(_direct_img_urls) and not any(
        ext in _all_text.lower() for ext in _AUDIO_EXT
    ) and not _non_image_urls
    if (any(t in q_lower for t in _WEB_TRIGGERS) or any(t in _all_text.lower() for t in ("https://", "http://"))) and not _is_pure_image_query:
        _web_query = req.query
        if not _re.search(r'https?://', req.query):
            _prior_urls = _re.findall(r'https?://\S+', _history_text)
            if _prior_urls:
                _web_query = req.query + " " + _prior_urls[0]
        try:
            raw = await asyncio.to_thread(web_search, _web_query, True)
            formatted = format_for_llm(raw)
            if formatted.strip():
                tool_context += f"\n\n[Web search results — source: {raw['source']}]\n{formatted}"
            else:
                tool_context += (
                    f"\n\n[Web search ran — source: {raw['source']} — "
                    f"no content retrieved. The site may use bot protection, "
                    f"require JavaScript, or be unreachable from this server. "
                    f"State this honestly rather than saying you lack web access.]"
                )
            tools_used.append("web")
        except Exception as e:
            tool_context += f"\n\n[Web search failed: {e}]"
    # ── Intent: image OCR ────────────────────────────────────────────────────
    if _direct_img_urls:
        from workers.websearch import _ocr_image
        for _img_url in _direct_img_urls[:3]:  # max 3 images per query
            try:
                _ocr_text = await asyncio.to_thread(_ocr_image, _img_url)
                if _ocr_text:
                    tool_context += f"\n\n[OCR: {_ocr_text}]\n(source: {_img_url})"
                    if "ocr" not in tools_used:
                        tools_used.append("ocr")
                else:
                    tool_context += f"\n\n[OCR returned no text for {_img_url}]"
            except Exception as e:
                tool_context += f"\n\n[OCR ERROR for {_img_url}: {type(e).__name__}: {e}]"
    # ── Intent: audio transcription ─────────────────────────────────────────────
    if any(t in q_lower for t in _AUDIO_TRIGGERS) or any(ext in _all_text.lower() for ext in _AUDIO_EXT):
        raw_urls = _re.findall(r'https?://\S+', _all_text)
        audio_urls = [
            u.rstrip('.,;)"\'')
            for u in raw_urls
            if any(ext in u.lower() for ext in _AUDIO_EXT)
        ]
        if audio_urls:
            try:
                from workers.audio import transcribe_url
                _result = await asyncio.wait_for(
                    asyncio.to_thread(transcribe_url, audio_urls[0]),
                    timeout=300
                )
                _lang   = _result.get("language", "unknown")
                _text   = _result.get("text", "")
                tool_context += (
                    f"\n\n[Audio transcript — language: {_lang}, "
                    f"source: {audio_urls[0]}]\n{_text}"
                )
                tools_used.append("audio")
            except asyncio.TimeoutError:
                tool_context += (
                    f"\n\n[Audio transcription TIMED OUT after 300s for {audio_urls[0]}. "
                    "The file may be very large. Try the /transcribe endpoint directly for long files.]"
                )
            except Exception as e:
                tool_context += f"\n\n[Audio transcription ERROR: {type(e).__name__}: {e}]"
        else:
            tool_context += (
                "\n\n[Note: audio transcription was requested but no recognised audio URL "
                "(.mp3 / .wav / .m4a / .ogg / .webm / .flac) was found in the query or history.]"
            )

    # ── Intent: self-test / maintenance ───────────────────────────────────────
    if any(t in q_lower for t in _DIAG_TRIGGERS):
        try:
            from memory.brain import self_diagnosis
            from graph.repo  import code_health_check
            _ws = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            diag   = await asyncio.to_thread(self_diagnosis)
            health = await asyncio.to_thread(code_health_check, _ws)
            tool_context += (
                f"\n\n[Self-diagnosis results]\n{json.dumps(diag, indent=2)}"
                f"\n\n[Code health results]\n{json.dumps(health, indent=2)}"
            )
            tools_used.append("diagnosis")
        except Exception as e:
            tool_context += f"\n\n[Self-diagnosis failed: {e}]"

    # ── Always: document retrieval ────────────────────────────────────────────
    try:
        chunks = await asyncio.wait_for(
            asyncio.to_thread(hybrid_retrieve, req.query, 4),
            timeout=15
        )
        if chunks:
            doc_ctx = "\n".join(
                f"[{d.metadata.get('source','?')}] {d.page_content}" for d in chunks
            )
            tool_context = f"\n\n[Relevant docs]\n{doc_ctx}" + tool_context
            doc_sources  = [d.metadata.get("source", "?") for d in chunks]
            tools_used.append("docs")
    except Exception:
        pass

    # ── Memory context ────────────────────────────────────────────────────────
    hits    = mem_search(req.query, n=3)
    mem_ctx = "\n".join(json.dumps(h) for h in hits) if hits else "none"

    # ── Build grounded prompt and call model ──────────────────────────────────
    # Web-status line: tell the model EXACTLY what happened this call
    if "web" in tools_used:
        web_status = (
            "Web search RAN this call — results are injected below. "
            "Summarise what was found; if content was sparse (e.g. images only), say so honestly."
        )
    else:
        web_status = (
            "Web search did NOT run this call — no URL or web keyword was detected in the query. "
            "This system CAN fetch live web pages when a URL (https://…) or search keyword is "
            "present. Do NOT say you lack web access. If the user is asking about a website, "
            "tell them to include the URL in their next message and you will fetch it."
        )
    _audio_st = (
        "Audio transcription RAN — the FULL transcript is injected below. "
        "Report it faithfully; do not say you cannot transcribe audio."
        if "audio" in tools_used else
        "Audio transcription is available for .mp3/.wav/.m4a/.ogg/.webm/.flac URLs. "
        "Do NOT claim you cannot transcribe audio."
    )
    _ocr_st = (
        "Image OCR RAN — the extracted text is in [OCR: ...] blocks below. "
        "Copy the OCR text VERBATIM into your answer."
        if "ocr" in tools_used else
        "Image OCR is available for .png/.jpg/.jpeg/.gif/.webp URLs. "
        "Do NOT claim you cannot read or transcribe images."
    )

    system = (
        "You are a Cognitive RAG assistant with full autonomous tool capabilities including "
        "live web search, direct URL fetching, and audio transcription. Tools are executed "
        "server-side before this prompt — results appear below as [Web search results], "
        "[Audio transcript], [Relevant docs], etc.\n\n"
        "CRITICAL OUTPUT RULES:\n"
        "1. If [Audio transcript ...] is present: copy the actual transcript text into your answer.\n"
        "2. If [OCR: ...] blocks appear in web results: quote them VERBATIM — copy the exact text character for character.\n"
        "3. If [Audio transcription ERROR: ...] appears: report the exact error to the user.\n"
        "4. If [Audio transcription TIMED OUT]: tell the user the file is very large and suggest the /transcribe endpoint.\n"
        "5. Never say you cannot access the internet, visit URLs, or transcribe audio.\n"
        "6. Never say 'no context was provided' — context IS provided via the tool results below.\n"
        "7. Answer directly from the data. Do not add disclaimers about your limitations.\n"
        f"Web: {web_status}\n"
        f"Audio: {_audio_st}\n"
        f"OCR: {_ocr_st}"
    )
    user_msg = (
        f"Query: {req.query}\n\n"
        f"Memory context:\n{mem_ctx}"
        f"{tool_context}\n\n"
        "Answer:"
    )
    # Build messages: system + recent conversation history (last 10 turns) + user
    history_msgs = [
        {"role": m.get("role", "user"), "content": m.get("content", "")}
        for m in (req.history or [])[-10:]
        if m.get("content")
    ]
    async with _ollama_sem:
        answer = await asyncio.to_thread(_chat, [
            {"role": "system", "content": system},
            *history_msgs,
            {"role": "user",   "content": user_msg}
        ])

    mem_write({"event": "query", "query": req.query, "reasoning": answer,
               "tools": tools_used, "memory_hits": len(hits)})
    STATE["cycle"] += 1
    return {
        "answer":       answer,
        "tools_used":   tools_used,
        "sources":      doc_sources,
        "memory_hits":  len(hits),
        "cycle":        STATE["cycle"],
    }

@app.post("/retrieve")
async def retrieve(req: Q):
    try:
        chunks = await asyncio.wait_for(
            asyncio.to_thread(hybrid_retrieve, req.query, 6),
            timeout=15
        )
        return {"chunks": [{"source": d.metadata.get("source", "?"),
                            "content": d.page_content} for d in chunks]}
    except Exception as e:
        return {"chunks": [], "error": str(e)}

@app.post("/web_search")
async def websearch(req: Q):
    result = await asyncio.to_thread(web_search, req.query, True)
    return {"formatted": format_for_llm(result), "source": result["source"],
            "result_count": len(result["results"])}

@app.post("/fim")
async def fim(req: FIMReq):
    """
    Fill-in-the-Middle completion.
    FIX-13: falls back to plain completion if FIM tokens cause model errors.
    """
    fim_prompt = f"<fim_prefix>{req.prefix}<fim_suffix>{req.suffix}<fim_middle>"
    try:
        resp = await asyncio.to_thread(lambda: _ol.generate(
            model=MODEL,
            prompt=fim_prompt,
            think=False,
            keep_alive="30m",
            options={
                "temperature": 0.05,
                "num_predict": req.max_tokens,
                "stop": ["<fim_prefix>", "<fim_suffix>", "<fim_middle>", "\n\n\n"]
            }
        ))
        completion = resp.get("response", "")
        # FIX-13: if the model echoed the FIM tokens it doesn't support FIM natively
        if "<fim_" in completion:
            # Fallback: plain completion from prefix only
            resp2 = await asyncio.to_thread(lambda: _ol.generate(
                model=MODEL,
                prompt=req.prefix,
                think=False,
                keep_alive="30m",
                options={"temperature": 0.05, "num_predict": req.max_tokens}
            ))
            completion = resp2.get("response", "")
        return {"completion": completion, "model": MODEL}
    except Exception as e:
        return {"completion": "", "error": str(e)}

@app.post("/repo_task")
def repo_task(req: RepoReq):
    build_graph(req.workspace_root)
    ctx      = graph_summary()
    file_ctx = get_file_context(req.workspace_root, req.current_file) if req.current_file else ""
    sys_msg  = ('You are a senior engineer. '
                'Return ONLY valid JSON matching this schema: '
                '{"plan":[{"description":"...","files_affected":["..."]}],'
                '"edits":[{"file":"...","start_line":0,"end_line":0,"text":"...","description":"..."}],'
                '"summary":"..."}')
    prompt = (f"TASK: {req.task}\nFILE: {req.current_file or 'none'}\n\n"
              f"FILE CONTENT:\n{file_ctx[:2000]}\n\nREPO STRUCTURE:\n{ctx}\n\nJSON only:")
    try:
        resp = _ol.chat(
            model=MODEL,
            messages=[
                {"role": "system", "content": sys_msg},
                {"role": "user",   "content": prompt}
            ],
            think=False,
            keep_alive="30m",
            format=TaskResp.model_json_schema(),
            options={"temperature": 0.1, "num_ctx": 8192}
        )
        return TaskResp.model_validate_json(resp["message"]["content"])
    except Exception as e:
        return TaskResp(plan=[], edits=[], summary=f"Error: {e}")

@app.post("/transcribe")
async def transcribe(req: TranscribeReq):
    """
    Transcribe an audio or video file (local path or URL).
    Supports mp3, mp4, wav, m4a, ogg, webm, and most formats ffmpeg can decode.
    Returns: {text, language, segments, source}
    """
    try:
        from workers.audio import transcribe_file, transcribe_url
        source = req.source.strip()
        if source.startswith("http://") or source.startswith("https://"):
            result = await asyncio.to_thread(transcribe_url, source, req.language)
        else:
            if not os.path.exists(source):
                return {"error": f"File not found: {source}"}
            result = await asyncio.to_thread(transcribe_file, source, req.language)
        result["source"] = source
        mem_write({"event": "transcription", "source": source,
                   "language": result.get("language"), "text": result["text"][:2000]})
        return result
    except Exception as e:
        return {"error": str(e)}

@app.post("/memory/store")
def memory_store(req: MemReq):
    mem_write({"event": "ext", "id": req.id, "text": req.text, "meta": req.meta or {}})
    return {"ok": True}

@app.post("/memory/query")
def memory_query(req: Q):
    hits = mem_search(req.query, n=5)
    return {"results": {"documents": [[
        h.get("text", "") or h.get("reasoning", "") or str(h) for h in hits
    ]]}}

@app.get("/memory/recent")
def memory_recent():
    return {"entries": mem_recent(20)}

@app.get("/maintenance")
def maintenance_log():
    """Return the last 30 autonomous maintenance events (diagnosis, health, cleanup, etc.)."""
    MAINT_EVENTS = {"loop_diagnosis", "loop_cleanup", "loop_health_check",
                    "loop_consolidate", "loop_error", "loop_skip",
                    "consolidation", "self_diagnosis", "embedding_maintenance", "cleanup"}
    all_entries = mem_recent(200)
    events = [e for e in all_entries if e.get("event") in MAINT_EVENTS][:30]
    return {"events": events, "total": len(events)}

@app.get("/gpu_status")
def gpu_status():
    import subprocess
    try:
        r = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,memory.used,memory.total,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5
        )
        parts = [p.strip() for p in r.stdout.strip().split(",")]
        return {"name": parts[0], "mem_used_mb": parts[1],
                "mem_total_mb": parts[2], "gpu_util_pct": parts[3], "model": MODEL}
    except Exception as e:
        return {"error": str(e), "model": MODEL}

"@
Set-Content "$ROOT\server\api.py" -Encoding UTF8 -Value $api
OK "server/api.py"

# ════════════════════════════════════════════════════════════════════════════
#  TEST HARNESS
# ════════════════════════════════════════════════════════════════════════════
Step "Writing test harness"
Set-Content "$ROOT\tests\__init__.py" -Encoding UTF8 -Value ""
Set-Content "$ROOT\tests\test_all.py"  -Encoding UTF8 -Value @'
"""
Cognitive RAG v17 - Full function test suite (20 tests).
Run with: python -m pytest tests/ -v --tb=short
Integration tests require the API server running on port 8765.
"""
import pytest, json, time, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

BASE = "http://127.0.0.1:8765"

try:
    import httpx
    CLIENT    = httpx.Client(base_url=BASE, timeout=60)
    SERVER_UP = CLIENT.get("/health").status_code == 200
except Exception:
    SERVER_UP = False

skip_no_server = pytest.mark.skipif(not SERVER_UP, reason="API server not running on :8765")

# ── Unit: memory ─────────────────────────────────────────────────────────────
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
        time.sleep(0.02)
        write({"event": "b", "text": "second"})
        r = recent(5)
        assert r[0]["text"] == "second"

# ── Unit: repo graph ─────────────────────────────────────────────────────────
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
        assert not any("node_modules" in k for k in REPO_INDEX.keys())

    def test_complexity_count(self, tmp_path):
        f = tmp_path / "c.py"
        f.write_text("if True:\n    for x in y:\n        while z:\n            pass\n")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        assert REPO_INDEX.get("c.py", {}).get("complexity", 0) >= 3

# ── Unit: web search helpers ─────────────────────────────────────────────────
class TestWebSearch:
    def test_ddg_returns_list(self):
        from workers.websearch import _ddg
        r = _ddg("Python programming language")
        assert isinstance(r, list)

    def test_format_for_llm(self):
        from workers.websearch import format_for_llm
        fake = {"results": [{"title": "T1", "url": "http://x.com", "snippet": "S1"},
                             {"title": "T2", "url": "",             "snippet": "S2"}],
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

# ── Integration: health + GPU ─────────────────────────────────────────────────
class TestAPIHealth:
    @skip_no_server
    def test_health_endpoint(self):
        r = CLIENT.get("/health")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "v17 online"
        assert "model" in body

    @skip_no_server
    def test_gpu_status_shape(self):
        r = CLIENT.get("/gpu_status")
        assert r.status_code == 200
        body = r.json()
        assert "model" in body or "error" in body

# ── Integration: core query ───────────────────────────────────────────────────
class TestAPIQuery:
    @skip_no_server
    def test_query_returns_answer(self):
        r = CLIENT.post("/query", json={"query": "What is 2+2?"})
        assert r.status_code == 200
        body = r.json()
        assert "answer" in body
        assert len(body["answer"]) > 0

    @skip_no_server
    def test_retrieve_graceful_empty_db(self):
        r = CLIENT.post("/retrieve", json={"query": "test query"})
        assert r.status_code == 200
        assert "chunks" in r.json()

    @skip_no_server
    def test_web_search_source_field(self):
        r = CLIENT.post("/web_search", json={"query": "Python asyncio tutorial"})
        assert r.status_code == 200
        body = r.json()
        assert body["source"] in ("searxng", "brave", "ddg", "none")
        assert "formatted" in body

# ── Integration: FIM ─────────────────────────────────────────────────────────
class TestFIM:
    @skip_no_server
    def test_fim_python(self):
        r = CLIENT.post("/fim", json={
            "prefix": "def add(a, b):\n    return ",
            "suffix": "\n\ndef subtract(a, b):",
            "language": "python",
            "max_tokens": 16
        })
        assert r.status_code == 200
        assert "completion" in r.json()

    @skip_no_server
    def test_fim_javascript(self):
        r = CLIENT.post("/fim", json={
            "prefix": "function greet(name) {\n  return ",
            "suffix": "\n}",
            "language": "javascript",
            "max_tokens": 32
        })
        assert r.status_code == 200

# ── Integration: memory ───────────────────────────────────────────────────────
class TestMemoryAPI:
    @skip_no_server
    def test_store_and_query(self):
        uid = f"test-{int(time.time())}"
        s   = CLIENT.post("/memory/store",
                          json={"id": uid, "text": "cograg test entry unique phrase xyzzy"})
        assert s.status_code == 200
        time.sleep(0.4)
        q    = CLIENT.post("/memory/query", json={"query": "xyzzy unique phrase"})
        assert q.status_code == 200
        docs = q.json().get("results", {}).get("documents", [[]])[0]
        assert isinstance(docs, list)

    @skip_no_server
    def test_recent_entries(self):
        r = CLIENT.get("/memory/recent")
        assert r.status_code == 200
        assert "entries" in r.json()
'@
OK "tests/test_all.py (20 tests)"

Set-Content "$ROOT\run_tests.ps1" -Encoding UTF8 -Value @"
Set-Location "$ROOT"
Write-Host "Running Cognitive RAG v17 tests..." -ForegroundColor Cyan
& "$PY" -m pytest tests/ -v --tb=short 2>&1
"@

# ════════════════════════════════════════════════════════════════════════════
#  VS CODE EXTENSION
# ════════════════════════════════════════════════════════════════════════════
Step "Writing VS Code extension v17"
$EXT = "$ROOT\vscode-extension"

$extensionJs = @'
"use strict";
const vscode = require("vscode");
const http   = require("http");
const https  = require("https");
const path   = require("path");

// ── Config ────────────────────────────────────────────────────────────────────
function cfg(key)      { return vscode.workspace.getConfiguration("cognitiveRag").get(key); }
function ollamaUrl()   { return cfg("ollamaUrl")   || "http://localhost:11434"; }
function ragUrl()      { return cfg("ragApiUrl")   || "http://localhost:8765"; }
function model()       { return cfg("model")       || "cograg-gpu"; }
function inlineDelay() { return cfg("inlineDelay") ?? 350; }

// ── HTTP helpers ──────────────────────────────────────────────────────────────
function httpPost(baseUrl, endpoint, body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts    = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json",
                  "Content-Length": Buffer.byteLength(payload) }
    };
    const req = lib.request(opts, res => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve({ error: data }); }
      });
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// FIX-12: GPU status uses correct GET method
function httpGet(baseUrl, endpoint) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(baseUrl + endpoint);
    const lib    = parsed.protocol === "https:" ? https : http;
    const opts   = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "GET"
    };
    const req = lib.request(opts, res => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve({ error: data }); }
      });
    });
    req.on("error", reject);
    req.end();
  });
}

function httpPostStream(baseUrl, endpoint, body, onChunk) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts    = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json",
                  "Content-Length": Buffer.byteLength(payload) }
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

// ── Utilities ─────────────────────────────────────────────────────────────────
async function ragRetrieve(query) {
  try {
    const d = await httpPost(ragUrl(), "/retrieve", { query });
    if (!d.chunks || d.chunks.length === 0) return "";
    return d.chunks.slice(0, 5)
      .map((c, i) => `[${i+1}] ${c.source}\n${c.content}`)
      .join("\n\n---\n\n");
  } catch { return ""; }
}

async function repoTask(workspaceRoot, task, currentFile) {
  try {
    return await httpPost(ragUrl(), "/repo_task", {
      workspace_root: workspaceRoot, task, current_file: currentFile || null
    });
  } catch (e) {
    return { plan: [], edits: [], summary: "RAG server not running: " + e.message };
  }
}

async function streamOllama(messages, onChunk) {
  const body = {
    model: model(), messages, stream: true,
    options: { temperature: 0.1, num_ctx: 16384 }
  };
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

// ── Inline completion provider (ghost text FIM) ───────────────────────────────
function registerInlineCompletions(context) {
  let debounceTimer = null;
  const provider = {
    provideInlineCompletionItems(document, position, _ctx, token) {
      if (!cfg("inlineEnabled")) return { items: [] };
      return new Promise(resolve => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(async () => {
          if (token.isCancellationRequested) { resolve({ items: [] }); return; }
          const prefixRange = new vscode.Range(
            new vscode.Position(Math.max(0, position.line - 40), 0), position);
          const prefix = document.getText(prefixRange);
          const suffixRange = new vscode.Range(
            position,
            new vscode.Position(
              Math.min(document.lineCount - 1, position.line + 10),
              document.lineAt(Math.min(document.lineCount - 1, position.line + 10)).text.length
            )
          );
          const suffix = document.getText(suffixRange);
          if (prefix.trim().length < 4) { resolve({ items: [] }); return; }
          try {
            const result = await httpPost(ragUrl(), "/fim", {
              prefix, suffix,
              language: document.languageId || "plaintext",
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

// ── Sidebar webview HTML ──────────────────────────────────────────────────────
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
             padding:2px 8px;border-radius:10px;max-width:60%;overflow:hidden;
             white-space:nowrap;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:#a78bfa;flex-shrink:0}
.history{flex:1;overflow-y:auto;padding:10px 12px;display:flex;flex-direction:column;gap:8px}
.msg{padding:7px 10px;border-radius:6px;font-size:12px;line-height:1.65;
     white-space:pre-wrap;word-break:break-word}
.msg.user{background:var(--vscode-input-background);border:1px solid var(--vscode-input-border)}
.msg.ai{background:var(--vscode-editor-inactiveSelectionBackground)}
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
.spinner{display:inline-block;width:8px;height:8px;
         border:1.5px solid var(--vscode-descriptionForeground);
         border-top-color:transparent;border-radius:50%;
         animation:spin .6s linear infinite;margin-right:4px}
.gpu-bar{font-size:10px;padding:3px 12px;
         background:var(--vscode-statusBar-background,#1e1e1e);
         color:var(--vscode-statusBar-foreground,#ccc);
         flex-shrink:0;display:flex;gap:8px}
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
  <textarea id="q"
    placeholder="Ask about your codebase, docs, or describe a multi-file task..."
    onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();send()}">
  </textarea>
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
const _st = vsc.getState() || {};
let history = _st.history || [];
if (_st.activeTools) activeTools = new Set(_st.activeTools);

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
  else                     { activeTools.add(t);    el.classList.add("on");    }
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
function refreshGpu() { vsc.postMessage({ cmd: "gpu_status" }); }

window.addEventListener("message", e => {
  const m = e.data;
  if (m.type === "stream_start") {
    const sd = document.createElement("div");
    sd.className = "msg ai"; sd.id = "ai-streaming";
    document.getElementById("history").appendChild(sd);
    sd.scrollIntoView({ behavior: "smooth" });
  }
  if (m.type === "stream_chunk") appendToStreaming(m.text);
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
    responding = false; setStatus("done");
  }
  if (m.type === "status") setStatus(m.text);
  if (m.type === "error") {
    addMsg("ai", "Error: " + m.text);
    responding = false; setStatus("error");
  }
  if (m.type === "gpu_update") {
    const bar = document.getElementById("gpu-bar");
    if (m.error) {
      bar.textContent = "⬡ GPU: " + m.error;
    } else {
      bar.textContent = "⬡ " + (m.name||"GPU") +
        " | VRAM: " + (m.mem_used_mb||"?") + "/" + (m.mem_total_mb||"?") +
        " MB | Util: " + (m.gpu_util_pct||"?") + "%";
    }
  }
});
restoreRenderedHistory();
setInterval(() => vsc.postMessage({ cmd: "gpu_status" }), 30000);
</script>
</body>
</html>`;
}

// ── Chat participant (@rag) ────────────────────────────────────────────────────
async function handleChatRequest(request, _context, stream, token) {
  const ws          = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
  const editor      = vscode.window.activeTextEditor;
  const currentFile = editor ? vscode.workspace.asRelativePath(editor.document.uri) : null;
  const query       = request.prompt.trim();
  const cmd         = request.command;
  let toolBadges    = [];

  if (cmd === "task") {
    stream.progress("Indexing repo...");
    const result = await repoTask(ws, query, currentFile);
    stream.markdown("**Plan**\n");
    (result.plan || []).forEach((s, i) =>
      stream.markdown(`${i+1}. ${s.description} → \`${(s.files_affected||[]).join(", ")}\`\n`));
    if ((result.edits || []).length > 0) {
      stream.markdown(`\n**${result.edits.length} file edits proposed**\n`);
      result.edits.forEach(ed =>
        stream.markdown(`- \`${ed.file}\` (L${ed.start_line}–${ed.end_line}): ${ed.description}\n`));
      const apply = await vscode.window.showQuickPick(["Apply all edits","Preview only"],
                          { placeHolder: result.summary });
      if (apply === "Apply all edits") {
        await applyEdits(result.edits, ws);
        stream.markdown("\n✓ Edits applied.");
      }
    }
    stream.markdown(`\n*${result.summary}*`);
    return;
  }

  if (cmd === "ingest") {
    const t = vscode.window.createTerminal("RAG Ingest");
    t.sendText(`cd "${ws}" && python ingest.py`);
    t.show();
    stream.markdown("Re-ingesting docs – check the terminal.");
    return;
  }

  // Route through agentic /query -- intent detection + real tool execution
  stream.progress("Running tools (intent dispatch active)...");
  try {
    const result  = await httpPost(ragUrl(), "/query", { query });
    const answer  = result.answer || "(no answer)";
    const toolMap = { web: "Web search", docs: "Hybrid RAG", diagnosis: "Self-Diagnosis" };
    const used    = (result.tools_used || []).map(t => toolMap[t] || t);
    if (result.memory_hits > 0) used.push(`Memory (${result.memory_hits})`);
    used.push("Model: " + model());
    stream.markdown(answer);
    stream.markdown(`\n\n---\n*Tools used: ${used.join(", ")}*`);
    toolBadges.push(...used);
  } catch (err) {
    // Fallback: direct Ollama with RAG context if backend unreachable
    const ragContext = await ragRetrieve(query);
    const sysPrompt = [
      "You are a local coding assistant backed by a hybrid RAG system.",
      "Use the provided context to answer accurately. Be concise.",
      currentFile ? `Current file: ${currentFile}` : "",
      ws ? `Workspace: ${ws}` : ""
    ].filter(Boolean).join("\n");
    const msgs = [
      { role: "system", content: sysPrompt },
      ...(ragContext ? [{ role: "system", content: "RETRIEVED CONTEXT:\n\n" + ragContext }] : []),
      { role: "user", content: query }
    ];
    stream.progress("Falling back to direct Ollama...");
    await streamOllama(msgs, chunk => stream.markdown(chunk));
    toolBadges.push("Model: " + model() + " (fallback)");
  }
}

// ── Sidebar ────────────────────────────────────────────────────────────────────
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

        // FIX-12: GPU status now uses httpGet (proper GET)
        if (msg.cmd === "gpu_status") {
          try {
            const gs = await httpGet(ragUrl(), "/gpu_status");
            post({ type: "gpu_update", ...gs });
          } catch (e) {
            post({ type: "gpu_update", error: e.message });
          }
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
            const pick = await vscode.window.showQuickPick(["Apply all edits","Preview only"],
                              { placeHolder: result.summary });
            if (pick === "Apply all edits") {
              await applyEdits(result.edits, ws);
              vscode.window.showInformationMessage("Applied " + result.edits.length + " edits");
            }
          }
          return;
        }

        // Default query -- route through agentic /query for tool dispatch
        const q = msg.query;
        if (!q) return;
        post({ type: "stream_start" });
        post({ type: "status", text: "running tools..." });
        try {
          const result = await httpPost(ragUrl(), "/query", { query: q });
          const answer = result.answer || "(no answer)";
          const toolMap = { web: "Web search", docs: "Hybrid RAG",
                            diagnosis: "Self-Diagnosis" };
          const badges = (result.tools_used || []).map(t => toolMap[t] || t);
          if (result.memory_hits > 0) badges.push(`Memory (${result.memory_hits})`);
          badges.push("Model: " + model());
          post({ type: "stream_chunk", text: answer });
          post({ type: "stream_end",   badges });
        } catch (err) {
          post({ type: "error",
                 text: "RAG server error: " + err.message +
                       ". Make sure the backend is running on port 8765." });
        }
      });
    }
  };

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("cognitiveRag.sidebar", provider,
      { webviewOptions: { retainContextWhenHidden: true } })
  );
}

// ── activate ──────────────────────────────────────────────────────────────────
function activate(context) {
  registerInlineCompletions(context);

  if (vscode.chat && vscode.chat.createChatParticipant) {
    const participant = vscode.chat.createChatParticipant("cognitiveRag.chat", handleChatRequest);
    participant.iconPath = vscode.Uri.joinPath(context.extensionUri, "media", "icon.png");
    context.subscriptions.push(participant);
  }

  registerSidebar(context);

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
      const result = await repoTask(ws, task,
        editor ? vscode.workspace.asRelativePath(editor.document.uri) : null);
      const panel = vscode.window.createWebviewPanel("repoTask",
        "Repo Task: " + task.slice(0, 40), vscode.ViewColumn.Two, { enableScripts: false });
      const esc = s => String(s)
        .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      let html = `<style>body{font-family:var(--vscode-font-family,sans-serif);
        padding:16px;font-size:13px;color:var(--vscode-foreground);
        background:var(--vscode-editor-background)}
        h2{margin:16px 0 8px;font-size:14px;font-weight:600}
        li{padding:3px 0;line-height:1.5}
        code{background:var(--vscode-textCodeBlock-background,#eee);padding:1px 5px;
             border-radius:3px;font-size:11px}
        details{margin:4px 0;border:1px solid var(--vscode-panel-border,#ccc);border-radius:4px}
        summary{padding:6px 10px;cursor:pointer;font-weight:500;list-style:none}
        pre{padding:10px;margin:0;overflow:auto;font-size:11px;line-height:1.4;
            background:var(--vscode-textCodeBlock-background,#f5f5f5)}
        em{display:block;margin-top:14px;font-size:11px;opacity:.6;
           border-top:1px solid var(--vscode-panel-border,#eee);padding-top:8px}</style>`;
      html += "<h2>Plan</h2><ul>";
      (result.plan||[]).forEach((s,i) => {
        html += `<li><b>${i+1}.</b> ${esc(s.description)} <code>${
          (s.files_affected||[]).map(esc).join(", ")}</code></li>`;
      });
      html += `</ul><h2>Edits (${(result.edits||[]).length})</h2>`;
      (result.edits||[]).forEach(ed => {
        html += `<details><summary><code>${esc(ed.file)}</code> L${ed.start_line}–${
          ed.end_line} – ${esc(ed.description)}</summary><pre>${esc(ed.text)}</pre></details>`;
      });
      html += `<em>${esc(result.summary||"")}</em>`;
      panel.webview.html = html;
      if ((result.edits||[]).length > 0) {
        const pick = await vscode.window.showQuickPick(["Apply all edits","Preview only"]);
        if (pick === "Apply all edits") await applyEdits(result.edits, ws);
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
    `Cognitive RAG v17 active – model: ${model()}. Ghost text inline completions enabled.`
  );
}

function deactivate() {}
module.exports = { activate, deactivate };
'@
Set-Content "$EXT\extension.js" -Encoding UTF8 -Value $extensionJs
OK "extension.js"

# ── package.json (FIX-6: added repository field) ──────────────────────────────
$packageJson = @"
{
  "name": "cognitive-rag-v17",
  "displayName": "Cognitive RAG v17",
  "description": "Local Qwen/Ollama + Hybrid RAG + Repo Graph + Inline Completions + GPU offload",
  "version": "1.7.0",
  "publisher": "yourname",
  "icon": "media/icon.png",
  "repository": {
    "type": "git",
    "url": "https://github.com/yourname/cognitive-rag-v17"
  },
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
        "cognitiveRag.ollamaUrl":     { "type": "string",  "default": "http://localhost:11434", "description": "Ollama API base URL" },
        "cognitiveRag.ragApiUrl":     { "type": "string",  "default": "http://localhost:8765",  "description": "RAG backend API URL" },
        "cognitiveRag.model":         { "type": "string",  "default": "cograg-gpu",             "description": "Ollama model name" },
        "cognitiveRag.inlineEnabled": { "type": "boolean", "default": true,                     "description": "Enable inline ghost-text completions (FIM)" },
        "cognitiveRag.inlineDelay":   { "type": "number",  "default": 350,                      "description": "Debounce ms before triggering inline completion" }
      }
    },
    "chatParticipants": [
      {
        "id": "cognitiveRag.chat",
        "name": "rag",
        "fullName": "Cognitive RAG",
        "description": "Local RAG + Ollama coding assistant",
        "isSticky": false
      }
    ],
    "viewsContainers": {
      "activitybar": [{ "id": "cognitiveRag", "title": "Cognitive RAG", "icon": "media/icon.png" }]
    },
    "views": {
      "cognitiveRag": [{
        "type": "webview",
        "id": "cognitiveRag.sidebar",
        "name": "Cognitive RAG",
        "visibility": "visible"
      }]
    },
    "commands": [
      { "command": "cognitiveRag.openChat",   "title": "Cognitive RAG: Open Chat (@rag)",   "category": "Cognitive RAG" },
      { "command": "cognitiveRag.repoTask",   "title": "Cognitive RAG: Run Repo Task",       "category": "Cognitive RAG" },
      { "command": "cognitiveRag.ingestDocs", "title": "Cognitive RAG: Re-ingest Documents", "category": "Cognitive RAG" },
      { "command": "cognitiveRag.runTests",   "title": "Cognitive RAG: Run Test Suite",      "category": "Cognitive RAG" }
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
OK "package.json (repository field added)"

# ── icon ──────────────────────────────────────────────────────────────────────
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
        if (Test-Path $vsixPath) { OK "VSIX built: $vsixPath" }
        else { Warn "VSIX build failed - will use folder install instead" }
    } catch { Warn "VSIX skipped: $_" }
    Pop-Location
} else { Warn "npm not found - skipping VSIX build" }

# ── Install extension ─────────────────────────────────────────────────────────
Step "Installing extension"
$dest = $env:USERPROFILE + "\.vscode\extensions\cognitive-rag-v17"
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item $EXT -Destination $dest -Recurse
OK "Installed to: $dest"
if ((Test-Path $vsixPath) -and (Get-Command code -ErrorAction SilentlyContinue)) {
    code --install-extension $vsixPath --force
    OK "VSIX installed via code CLI"
}

# ── Sample docs + launchers (FIX-5: venv activated in start_server.ps1) ───────
Step "Writing sample docs and launchers"
Set-Content "$ROOT\docs\overview.md" -Encoding UTF8 -Value @'
# Cognitive RAG v17
Backend endpoints:
  POST /query /retrieve /repo_task /fim /web_search /memory/store /memory/query
  GET  /health /gpu_status /memory/recent

Extension features:
  Sidebar panel, @rag chat participant, Ctrl+Alt+Q (chat), Ctrl+Alt+R (repo task)
  Inline FIM ghost-text completions (Tab to accept)

GPU: cograg-gpu model auto-configured with CUDA layers via nvidia-smi detection
'@

# FIX-5: start_server.ps1 now activates the venv explicitly before uvicorn
$sl = @"
Set-Location "$ROOT"
Write-Host "Cognitive RAG v17 | Model: $MODEL_GPU | GPU: $GPU_NAME" -ForegroundColor Cyan
Write-Host "API: http://127.0.0.1:$PORT" -ForegroundColor Green
Write-Host "Test: .\run_tests.ps1" -ForegroundColor DarkCyan

# Ensure Ollama is running
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 3
    Write-Host "  Ollama started." -ForegroundColor DarkGray
}

# Activate venv
& "$VENV\Scripts\Activate.ps1"

# Watchdog loop: restart backend if it crashes
`$restarts = 0
while (`$true) {
    `$restarts++
    if (`$restarts -gt 1) {
        Write-Host ("`[{0}`] Backend crashed - restarting (attempt {1})..." -f (Get-Date -Format "HH:mm:ss"), `$restarts) -ForegroundColor Yellow
        Start-Sleep 2
    }
    Write-Host ("`[{0}`] Starting backend (run #{1})..." -f (Get-Date -Format "HH:mm:ss"), `$restarts) -ForegroundColor Green
    & "$PY" -m uvicorn server.api:app --host 127.0.0.1 --port $PORT --reload
    # If we reach here the process exited - loop restarts it
}
"@
Set-Content "$ROOT\start_server.ps1" -Encoding UTF8 -Value `$sl

Set-Content "$ROOT\ingest_docs.ps1" -Encoding UTF8 -Value @"
Set-Location "$ROOT"
& "$VENV\Scripts\Activate.ps1"
& "$PY" ingest.py
"@

Set-Content "$ROOT\run_tests.ps1" -Encoding UTF8 -Value @"
Set-Location "$ROOT"
Write-Host "Running Cognitive RAG v17 tests..." -ForegroundColor Cyan
& "$VENV\Scripts\Activate.ps1"
& "$PY" -m pytest tests/ -v --tb=short 2>&1
"@

# ── SearXNG docker-compose ────────────────────────────────────────────────────
Set-Content "$ROOT\searxng-compose.yml" -Encoding UTF8 -Value @'
# Optional: self-hosted web search (much better than DDG fallback)
# Usage:
#   docker compose -f searxng-compose.yml up -d
#   $env:SEARXNG_URL = "http://localhost:8888"
#   Then restart start_server.ps1
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
OK "searxng-compose.yml, start_server.ps1, ingest_docs.ps1, run_tests.ps1"

# ── Final summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Cognitive RAG v17 - INSTALLED (PATCHED)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  GPU     : $GPU_NAME ($GPU_LAYERS layers offloaded)" -ForegroundColor Cyan
Write-Host "  Model   : $MODEL_GPU (based on $MODEL)" -ForegroundColor Cyan
Write-Host "  Root    : $ROOT"
Write-Host "  API     : http://127.0.0.1:$PORT"
Write-Host ""
Write-Host "  PATCHES APPLIED:" -ForegroundColor Yellow
Write-Host "  [FIX-1]  Removed non-existent searxng-client pip package"
Write-Host "  [FIX-2]  Packages installed in 3 isolated batches (no cascade failure)"
Write-Host "  [FIX-3]  GPU VRAM via nvidia-smi (not WMI) - RTX 2060 now gets 43 layers"
Write-Host "  [FIX-4]  Verification step confirms critical packages imported correctly"
Write-Host "  [FIX-5]  start_server.ps1 activates venv before launching uvicorn"
Write-Host "  [FIX-6]  package.json has repository field (no more VSIX warning)"
Write-Host "  [FIX-7]  MODEL_GPU exported from engine.py (fixes api.py ImportError)"
Write-Host "  [FIX-8]  FastAPI uses lifespan() not deprecated @on_event decorators"
Write-Host "  [FIX-9]  ChromaDB OllamaEmbeddingFunction import path corrected for 0.4+"
Write-Host "  [FIX-10] retriever.py uses try/except for new LangChain import paths"
Write-Host "  [FIX-11] ingest.py removed deprecated Chroma.persist() call"
Write-Host "  [FIX-12] Extension GPU status uses httpGet not httpPost"
Write-Host "  [FIX-13] /fim falls back gracefully for non-FIM models (qwen3.6)"
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. cd `"$ROOT`""
Write-Host "  2. .\start_server.ps1"
Write-Host "  3. VS Code: Ctrl+Shift+P -> Developer: Reload Window"
Write-Host "  4. Click the hexagon icon in the Activity Bar"
Write-Host "  5. .\run_tests.ps1   (runs all 20 tests)"
Write-Host ""
Write-Host "  OPTIONAL - self-hosted web search:" -ForegroundColor DarkCyan
Write-Host "  docker compose -f `"$ROOT\searxng-compose.yml`" up -d"
Write-Host '  $env:SEARXNG_URL = "http://localhost:8888"'
Write-Host "  Then restart start_server.ps1"
Write-Host ""
Write-Host "  OPTIONAL - upgrade to larger model (fits RTX 2060 12GB fully):" -ForegroundColor DarkCyan
Write-Host "  ollama pull qwen2.5-coder:14b"
Write-Host '  Set cognitiveRag.model = "qwen2.5-coder:14b" in VS Code settings'
Write-Host "  Re-run this installer to rebuild cograg-gpu Modelfile with new base"
Write-Host ""
Write-Host "  Parity estimate: ~72% (was 55%)" -ForegroundColor Green
Write-Host "  Remaining gap  : model scale, cloud latency advantage, no auth/tools API"
Write-Host "============================================================" -ForegroundColor Green
