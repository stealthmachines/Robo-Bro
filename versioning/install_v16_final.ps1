#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  COGNITIVE RAG v16 - COMPLETE INSTALLER (FINAL)
#  Fixes vs working zip:
#    1. Web search button: real DuckDuckGo API (no key needed)
#    2. Session history: persists across panel hide/show
#    3. ollama pull: Start-Process (no unicode pipe crash)
#    4. Model: prefers qwen3.6 over qwen3
#  extension.js, icon.png, package.json embedded as base64.
# ================================================================

$ROOT  = "$HOME\cognitive-rag-v16"
$VENV  = "$ROOT\.venv"
$PY    = "$VENV\Scripts\python.exe"
$PORT  = 8765
$EMBED = "nomic-embed-text"

function Step($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "   OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   !!: $m" -ForegroundColor Yellow }

# ----------------------------------------------------------------
# STEP 1 - DIRECTORIES
# ----------------------------------------------------------------
Step "Creating directories"
foreach ($d in @(
    $ROOT, "$ROOT\core", "$ROOT\memory", "$ROOT\server",
    "$ROOT\workers", "$ROOT\graph", "$ROOT\docs", "$ROOT\chroma_db",
    "$ROOT\vscode-extension", "$ROOT\vscode-extension\media"
)) { if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
OK $ROOT

# ----------------------------------------------------------------
# STEP 2 - DETECT MODEL
# ----------------------------------------------------------------
Step "Detecting Ollama model"
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 4
}
$MODEL = "qwen3.6:latest"
try {
    $tags     = Invoke-RestMethod "http://localhost:11434/api/tags" -TimeoutSec 6
    $allNames = @($tags.models | ForEach-Object { $_.name })
    Write-Host "   Models: $($allNames -join ', ')" -ForegroundColor DarkCyan
    $pick = $allNames | Where-Object { $_ -match "^qwen3\.6" }     | Select-Object -First 1
    if (-not $pick) { $pick = $allNames | Where-Object { $_ -match "qwen3-coder" } | Select-Object -First 1 }
    if (-not $pick) { $pick = $allNames | Where-Object { $_ -match "^qwen3:" }     | Select-Object -First 1 }
    if ($pick) { $MODEL = $pick }
    OK "Model: $MODEL"
} catch { Warn "Ollama not responding - defaulting to $MODEL" }

# ----------------------------------------------------------------
# STEP 3 - PULL MODELS (Start-Process - no unicode pipe crash)
# ----------------------------------------------------------------
Step "Pulling models"
foreach ($m in @($MODEL, $EMBED)) {
    Write-Host "   Pulling $m ..." -ForegroundColor DarkCyan
    $p = Start-Process "ollama" -ArgumentList "pull",$m -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) { OK "$m ready" } else { Warn "$m exit $($p.ExitCode) - may already exist" }
}

# ----------------------------------------------------------------
# STEP 4 - PYTHON VENV + PACKAGES
# ----------------------------------------------------------------
Step "Python environment"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "Python not found." }
if (!(Test-Path $VENV)) { python -m venv $VENV }
OK "venv ready"
Step "Installing packages"
& $PY -m pip install --upgrade pip --quiet
& $PY -m pip install fastapi "uvicorn[standard]" pydantic `
    langchain langchain-community langchain-text-splitters `
    chromadb faiss-cpu rank_bm25 ollama httpx requests `
    unstructured pypdf --quiet
OK "Packages installed"

# ----------------------------------------------------------------
# STEP 5 - MEMORY ENGINE
# ----------------------------------------------------------------
Step "Writing memory engine"
Set-Content "$ROOT\memory\brain.py" -Encoding UTF8 -Value @'
import json, os, time
DB = "./memory/cognition.jsonl"

def write(entry: dict):
    os.makedirs("memory", exist_ok=True)
    with open(DB, "a", encoding="utf-8") as f:
        f.write(json.dumps({"t": time.time(), **entry}) + "\n")

def load() -> list:
    if not os.path.exists(DB): return []
    out = []
    with open(DB, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try: out.append(json.loads(line))
                except: pass
    return out

def search(query: str, n: int = 5) -> list:
    data   = load()
    terms  = query.lower().split()
    scored = [(sum(json.dumps(d).lower().count(t) for t in terms), d) for d in data]
    scored = [(s,d) for s,d in scored if s > 0]
    scored.sort(key=lambda x: x[0], reverse=True)
    return [d for _, d in scored[:n]]

def recent(n: int = 20) -> list:
    return sorted(load(), key=lambda x: x.get("t",0), reverse=True)[:n]
'@
Set-Content "$ROOT\memory\__init__.py" -Encoding UTF8 -Value ""
OK "memory/brain.py"

# ----------------------------------------------------------------
# STEP 6 - COGNITION ENGINE (real Ollama, no stubs)
# ----------------------------------------------------------------
Step "Writing cognition engine"
$eng = @"
import asyncio, json, time, traceback, urllib.request
from memory.brain import write, search

MODEL = "$MODEL"
STATE = {"cycle": 0, "running": True}

def _chat(messages, temp=0.1):
    body = json.dumps({"model":MODEL,"messages":messages,"stream":False,"options":{"temperature":temp,"num_ctx":4096}}).encode()
    req  = urllib.request.Request("http://localhost:11434/api/chat",data=body,headers={"Content-Type":"application/json"},method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read()).get("message",{}).get("content","")
    except Exception as e:
        return f"[ollama error: {e}]"

async def cognition_cycle(query: str) -> dict:
    STATE["cycle"] += 1
    cid = STATE["cycle"]
    write({"event":"cycle_start","cycle":cid,"query":query})
    hits = search(query, n=3)
    mem  = "\n".join(json.dumps(h) for h in hits) if hits else "none"
    reasoning = await asyncio.to_thread(_chat,[
        {"role":"system","content":"You are a concise reasoning engine."},
        {"role":"user","content":f"Query: {query}\nMemory:\n{mem}\nAnswer concisely."}
    ])
    reflection = await asyncio.to_thread(_chat,[
        {"role":"user","content":f"One sentence to remember: Q={query} A={reasoning[:200]}"}
    ], 0.2)
    write({"event":"cycle_end","cycle":cid,"query":query,"reasoning":reasoning,"reflection":reflection})
    return {"cycle":cid,"query":query,"reasoning":reasoning,"reflection":reflection,"memory_hits":len(hits)}

async def background_loop():
    probes = ["What patterns emerged?","What knowledge gaps exist?","What changed recently?"]
    i = 0
    while STATE["running"]:
        try: await cognition_cycle(probes[i % 3]); i += 1
        except Exception as e: write({"event":"loop_error","error":str(e),"trace":traceback.format_exc()})
        await asyncio.sleep(60)

async def run(query: str) -> dict:
    return await cognition_cycle(query)

def stop():
    STATE["running"] = False
"@
Set-Content "$ROOT\core\engine.py" -Encoding UTF8 -Value $eng
Set-Content "$ROOT\core\__init__.py" -Encoding UTF8 -Value ""
OK "core/engine.py"

# ----------------------------------------------------------------
# STEP 7 - HYBRID RETRIEVER
# ----------------------------------------------------------------
Step "Writing retriever"
Set-Content "$ROOT\workers\retriever.py" -Encoding UTF8 -Value @'
import pickle, sys
sys.path.insert(0,".")
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
_cache = {}

def _load():
    if "vs" not in _cache:
        emb = OllamaEmbeddings(model="nomic-embed-text",base_url="http://localhost:11434")
        _cache["vs"] = Chroma(persist_directory="./chroma_db",embedding_function=emb)
        try:
            d = pickle.load(open("bm25_index.pkl","rb"))
            _cache["bm25"] = d["bm25"]; _cache["chunks"] = d["chunks"]
        except: _cache["bm25"] = None; _cache["chunks"] = []
    return _cache

def _rrf(lists, k=60):
    scores, docs = {}, {}
    for lst in lists:
        for rank, doc in enumerate(lst):
            key = doc.page_content[:120]
            scores[key] = scores.get(key,0) + 1/(rank+k)
            docs[key]   = doc
    return [docs[k] for k,_ in sorted(scores.items(),key=lambda x:x[1],reverse=True)]

def retrieve(query, top_k=6):
    c = _load()
    dense = c["vs"].similarity_search(query, k=top_k)
    sparse = []
    if c["bm25"]:
        sc  = c["bm25"].get_scores(query.lower().split())
        idx = sorted(range(len(sc)),key=lambda i:sc[i],reverse=True)[:top_k]
        sparse = [c["chunks"][i] for i in idx]
    return _rrf([dense,sparse])[:top_k]
'@
Set-Content "$ROOT\workers\__init__.py" -Encoding UTF8 -Value ""
OK "workers/retriever.py"

# ----------------------------------------------------------------
# STEP 8 - REPO GRAPH
# ----------------------------------------------------------------
Step "Writing repo graph"
Set-Content "$ROOT\graph\repo.py" -Encoding UTF8 -Value @'
from pathlib import Path
import re
REPO_INDEX = {}
CODE_EXTS  = {".py",".js",".ts",".jsx",".tsx",".go",".rs",".java",".cs",".cpp",".c",".rb",".vue"}
SYM_RE     = re.compile(r"^(?:def |class |function |const |let |var |func |pub fn |fn |async fn |export )([A-Za-z_]\w*)",re.MULTILINE)
IGNORE     = {"node_modules",".venv","__pycache__",".git","dist","build"}

def build(workspace_root):
    REPO_INDEX.clear()
    root = Path(workspace_root)
    for ext in CODE_EXTS:
        for f in root.rglob(f"*{ext}"):
            if any(p in f.parts for p in IGNORE): continue
            try:
                rel = str(f.relative_to(root))
                content = f.read_text(encoding="utf-8",errors="ignore")
                REPO_INDEX[rel] = {"symbols":SYM_RE.findall(content)[:20],"lines":content.count("\n")}
            except: pass
    return {"files": len(REPO_INDEX)}

def summary(max_files=25):
    out = []
    for f,d in list(REPO_INDEX.items())[:max_files]:
        syms = ", ".join(d["symbols"][:6]) if d["symbols"] else "-"
        out.append(f"{f} ({d[chr(108)+chr(105)+chr(110)+chr(101)+chr(115)]} lines) [{syms}]")
    return "\n".join(out) or "No files indexed."
'@
Set-Content "$ROOT\graph\__init__.py" -Encoding UTF8 -Value ""
OK "graph/repo.py"

# ----------------------------------------------------------------
# STEP 9 - INGEST
# ----------------------------------------------------------------
Step "Writing ingest.py"
Set-Content "$ROOT\ingest.py" -Encoding UTF8 -Value @'
import sys, pickle
sys.path.insert(0,".")
from langchain_community.document_loaders import DirectoryLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.vectorstores import Chroma
from langchain_community.embeddings import OllamaEmbeddings
from rank_bm25 import BM25Okapi

def ingest():
    print("Loading ./docs/ ...")
    docs = DirectoryLoader("./docs",glob="**/*.{md,txt,pdf}",show_progress=True).load()
    if not docs: print("No docs found. Add .md/.txt/.pdf to ./docs/"); return
    chunks = RecursiveCharacterTextSplitter(chunk_size=512,chunk_overlap=64).split_documents(docs)
    print(f"  {len(chunks)} chunks from {len(docs)} docs")
    emb = OllamaEmbeddings(model="nomic-embed-text",base_url="http://localhost:11434")
    Chroma.from_documents(chunks,emb,persist_directory="./chroma_db").persist()
    bm25 = BM25Okapi([c.page_content.lower().split() for c in chunks])
    pickle.dump({"bm25":bm25,"chunks":chunks},open("bm25_index.pkl","wb"))
    print("Done.")

if __name__ == "__main__": ingest()
'@
OK "ingest.py"

# ----------------------------------------------------------------
# STEP 10 - FASTAPI SERVER
# ----------------------------------------------------------------
Step "Writing FastAPI server"
Set-Content "$ROOT\server\__init__.py" -Encoding UTF8 -Value ""
$api = @"
import sys,os,asyncio
sys.path.insert(0,os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List,Optional
import ollama as _ol
from core.engine import run as cog_run,background_loop,stop as cog_stop,STATE
from workers.retriever import retrieve as hybrid_retrieve
from graph.repo import build as build_graph,summary as graph_summary
from memory.brain import write as mem_write,search as mem_search,recent as mem_recent

MODEL = "$MODEL"
app   = FastAPI(title="Cognitive RAG v16")
app.add_middleware(CORSMiddleware,allow_origins=["*"],allow_methods=["*"],allow_headers=["*"])

@app.on_event("startup")
async def startup(): asyncio.create_task(background_loop())
@app.on_event("shutdown")
async def shutdown(): cog_stop()

class Q(BaseModel): query: str
class RepoReq(BaseModel):
    workspace_root:str; task:str; current_file:Optional[str]=None
class PlanStep(BaseModel): description:str; files_affected:List[str]
class Edit(BaseModel): file:str; start_line:int; end_line:int; text:str; description:str
class TaskResp(BaseModel): plan:List[PlanStep]; edits:List[Edit]; summary:str
class MemReq(BaseModel): id:str; text:str; meta:Optional[dict]=None

@app.get("/health")
def health(): return {"status":"v16 online","model":MODEL,"cycle":STATE["cycle"]}

@app.post("/query")
async def query(req:Q):
    r = await cog_run(req.query)
    return {"answer":r["reasoning"],"reflection":r["reflection"],"memory_hits":r["memory_hits"],"cycle":r["cycle"]}

@app.post("/retrieve")
def retrieve(req:Q):
    try:
        chunks = hybrid_retrieve(req.query,top_k=6)
        return {"chunks":[{"source":d.metadata.get("source","?"),"content":d.page_content} for d in chunks]}
    except Exception as e: return {"chunks":[],"error":str(e)}

@app.post("/repo_task")
def repo_task(req:RepoReq):
    build_graph(req.workspace_root)
    ctx = graph_summary()
    sys_msg = 'You are a senior engineer. Return ONLY valid JSON: {"plan":[{"description":"...","files_affected":["..."]}],"edits":[{"file":"...","start_line":0,"end_line":0,"text":"...","description":"..."}],"summary":"..."}'
    prompt  = f"TASK: {req.task}\nFILE: {req.current_file or 'none'}\n\nREPO:\n{ctx}\n\nJSON only:"
    try:
        resp = _ol.chat(model=MODEL,messages=[{"role":"system","content":sys_msg},{"role":"user","content":prompt}],
                        format=TaskResp.model_json_schema(),options={"temperature":0.1,"num_ctx":32768})
        return TaskResp.model_validate_json(resp["message"]["content"])
    except Exception as e: return TaskResp(plan=[],edits=[],summary=f"Error: {e}")

@app.post("/memory/store")
def memory_store(req:MemReq):
    mem_write({"event":"ext","id":req.id,"text":req.text,"meta":req.meta or {}})
    return {"ok":True}

@app.post("/memory/query")
def memory_query(req:Q):
    hits = mem_search(req.query,n=5)
    return {"results":{"documents":[[h.get("text","") or h.get("reasoning","") or str(h) for h in hits]]}}

@app.get("/memory/recent")
def memory_recent(): return {"entries":mem_recent(20)}
"@
Set-Content "$ROOT\server\api.py" -Encoding UTF8 -Value $api
OK "server/api.py"

# ----------------------------------------------------------------
# STEP 11 - VS CODE EXTENSION (patched originals, base64)
# ----------------------------------------------------------------
Step "Writing VS Code extension files"
$EXT = "$ROOT\vscode-extension"

$jsB64  = "Y29uc3QgdnNjb2RlID0gcmVxdWlyZSgidnNjb2RlIik7DQpjb25zdCBodHRwICAgPSByZXF1aXJlKCJodHRwIik7DQpjb25zdCBodHRwcyAgPSByZXF1aXJlKCJodHRwcyIpOw0KY29uc3QgcGF0aCAgID0gcmVxdWlyZSgicGF0aCIpOw0KDQovLyDilIDilIDilIAgQ29uZmlnIGhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQpmdW5jdGlvbiBjZmcoa2V5KSB7DQogIHJldHVybiB2c2NvZGUud29ya3NwYWNlLmdldENvbmZpZ3VyYXRpb24oImNvZ25pdGl2ZVJhZyIpLmdldChrZXkpOw0KfQ0KZnVuY3Rpb24gb2xsYW1hVXJsKCkgeyByZXR1cm4gY2ZnKCJvbGxhbWFVcmwiKSB8fCAiaHR0cDovL2xvY2FsaG9zdDoxMTQzNCI7IH0NCmZ1bmN0aW9uIHJhZ1VybCgpICAgIHsgcmV0dXJuIGNmZygicmFnQXBpVXJsIikgIHx8ICJodHRwOi8vbG9jYWxob3N0Ojg3NjUiOyB9DQpmdW5jdGlvbiBtb2RlbCgpICAgICB7IHJldHVybiBjZmcoIm1vZGVsIikgICAgICB8fCAicXdlbjMuNjpsYXRlc3QiOyB9DQoNCi8vIOKUgOKUgOKUgCBIVFRQIGhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQpmdW5jdGlvbiBodHRwUG9zdChiYXNlVXJsLCBlbmRwb2ludCwgYm9keSkgew0KICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gew0KICAgIGNvbnN0IHBheWxvYWQgPSBKU09OLnN0cmluZ2lmeShib2R5KTsNCiAgICBjb25zdCBwYXJzZWQgID0gbmV3IFVSTChiYXNlVXJsICsgZW5kcG9pbnQpOw0KICAgIGNvbnN0IGxpYiAgICAgPSBwYXJzZWQucHJvdG9jb2wgPT09ICJodHRwczoiID8gaHR0cHMgOiBodHRwOw0KICAgIGNvbnN0IG9wdHMgPSB7DQogICAgICBob3N0bmFtZTogcGFyc2VkLmhvc3RuYW1lLA0KICAgICAgcG9ydDogICAgIHBhcnNlZC5wb3J0IHx8IChwYXJzZWQucHJvdG9jb2wgPT09ICJodHRwczoiID8gNDQzIDogODApLA0KICAgICAgcGF0aDogICAgIHBhcnNlZC5wYXRobmFtZSwNCiAgICAgIG1ldGhvZDogICAiUE9TVCIsDQogICAgICBoZWFkZXJzOiAgeyAiQ29udGVudC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24iLCAiQ29udGVudC1MZW5ndGgiOiBCdWZmZXIuYnl0ZUxlbmd0aChwYXlsb2FkKSB9DQogICAgfTsNCiAgICBjb25zdCByZXEgPSBsaWIucmVxdWVzdChvcHRzLCByZXMgPT4gew0KICAgICAgbGV0IGRhdGEgPSAiIjsNCiAgICAgIHJlcy5vbigiZGF0YSIsIGMgPT4gZGF0YSArPSBjKTsNCiAgICAgIHJlcy5vbigiZW5kIiwgICgpID0+IHsNCiAgICAgICAgdHJ5IHsgcmVzb2x2ZShKU09OLnBhcnNlKGRhdGEpKTsgfQ0KICAgICAgICBjYXRjaCB7IHJlc29sdmUoeyBlcnJvcjogZGF0YSB9KTsgfQ0KICAgICAgfSk7DQogICAgfSk7DQogICAgcmVxLm9uKCJlcnJvciIsIHJlamVjdCk7DQogICAgcmVxLndyaXRlKHBheWxvYWQpOw0KICAgIHJlcS5lbmQoKTsNCiAgfSk7DQp9DQoNCi8vIFN0cmVhbWluZyBQT1NUIOKAlCBjYWxscyBvbkNodW5rKHRleHQpIGZvciBlYWNoIHRva2VuDQpmdW5jdGlvbiBodHRwUG9zdFN0cmVhbShiYXNlVXJsLCBlbmRwb2ludCwgYm9keSwgb25DaHVuaykgew0KICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gew0KICAgIGNvbnN0IHBheWxvYWQgPSBKU09OLnN0cmluZ2lmeShib2R5KTsNCiAgICBjb25zdCBwYXJzZWQgID0gbmV3IFVSTChiYXNlVXJsICsgZW5kcG9pbnQpOw0KICAgIGNvbnN0IGxpYiAgICAgPSBwYXJzZWQucHJvdG9jb2wgPT09ICJodHRwczoiID8gaHR0cHMgOiBodHRwOw0KICAgIGNvbnN0IG9wdHMgPSB7DQogICAgICBob3N0bmFtZTogcGFyc2VkLmhvc3RuYW1lLA0KICAgICAgcG9ydDogICAgIHBhcnNlZC5wb3J0IHx8IChwYXJzZWQucHJvdG9jb2wgPT09ICJodHRwczoiID8gNDQzIDogODApLA0KICAgICAgcGF0aDogICAgIHBhcnNlZC5wYXRobmFtZSwNCiAgICAgIG1ldGhvZDogICAiUE9TVCIsDQogICAgICBoZWFkZXJzOiAgeyAiQ29udGVudC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24iLCAiQ29udGVudC1MZW5ndGgiOiBCdWZmZXIuYnl0ZUxlbmd0aChwYXlsb2FkKSB9DQogICAgfTsNCiAgICBjb25zdCByZXEgPSBsaWIucmVxdWVzdChvcHRzLCByZXMgPT4gew0KICAgICAgbGV0IGJ1ZiA9ICIiOw0KICAgICAgcmVzLm9uKCJkYXRhIiwgY2h1bmsgPT4gew0KICAgICAgICBidWYgKz0gY2h1bmsudG9TdHJpbmcoKTsNCiAgICAgICAgY29uc3QgbGluZXMgPSBidWYuc3BsaXQoIlxuIik7DQogICAgICAgIGJ1ZiA9IGxpbmVzLnBvcCgpOw0KICAgICAgICBmb3IgKGNvbnN0IGxpbmUgb2YgbGluZXMpIHsNCiAgICAgICAgICBpZiAoIWxpbmUudHJpbSgpKSBjb250aW51ZTsNCiAgICAgICAgICB0cnkgew0KICAgICAgICAgICAgY29uc3Qgb2JqID0gSlNPTi5wYXJzZShsaW5lKTsNCiAgICAgICAgICAgIGlmIChvYmoubWVzc2FnZSAmJiBvYmoubWVzc2FnZS5jb250ZW50KSBvbkNodW5rKG9iai5tZXNzYWdlLmNvbnRlbnQpOw0KICAgICAgICAgICAgaWYgKG9iai5kb25lKSByZXNvbHZlKCk7DQogICAgICAgICAgfSBjYXRjaCB7fQ0KICAgICAgICB9DQogICAgICB9KTsNCiAgICAgIHJlcy5vbigiZW5kIiwgKCkgPT4gcmVzb2x2ZSgpKTsNCiAgICB9KTsNCiAgICByZXEub24oImVycm9yIiwgcmVqZWN0KTsNCiAgICByZXEud3JpdGUocGF5bG9hZCk7DQogICAgcmVxLmVuZCgpOw0KICB9KTsNCn0NCg0KLy8g4pSA4pSA4pSAIFJBRyByZXRyaWV2YWwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQphc3luYyBmdW5jdGlvbiByYWdSZXRyaWV2ZShxdWVyeSkgew0KICB0cnkgew0KICAgIGNvbnN0IGQgPSBhd2FpdCBodHRwUG9zdChyYWdVcmwoKSwgIi9yZXRyaWV2ZSIsIHsgcXVlcnkgfSk7DQogICAgaWYgKCFkLmNodW5rcyB8fCBkLmNodW5rcy5sZW5ndGggPT09IDApIHJldHVybiAiIjsNCiAgICByZXR1cm4gZC5jaHVua3Muc2xpY2UoMCwgNSkubWFwKChjLCBpKSA9Pg0KICAgICAgYFske2krMX1dICR7Yy5zb3VyY2V9XG4ke2MuY29udGVudH1gDQogICAgKS5qb2luKCJcblxuLS0tXG5cbiIpOw0KICB9IGNhdGNoIHsNCiAgICByZXR1cm4gIiI7DQogIH0NCn0NCg0KLy8g4pSA4pSA4pSAIFJlcG8gZ3JhcGgg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQphc3luYyBmdW5jdGlvbiByZXBvVGFzayh3b3Jrc3BhY2VSb290LCB0YXNrLCBjdXJyZW50RmlsZSkgew0KICB0cnkgew0KICAgIHJldHVybiBhd2FpdCBodHRwUG9zdChyYWdVcmwoKSwgIi9yZXBvX3Rhc2siLCB7DQogICAgICB3b3Jrc3BhY2Vfcm9vdDogd29ya3NwYWNlUm9vdCwNCiAgICAgIHRhc2ssDQogICAgICBjdXJyZW50X2ZpbGU6IGN1cnJlbnRGaWxlIHx8IG51bGwNCiAgICB9KTsNCiAgfSBjYXRjaChlKSB7DQogICAgcmV0dXJuIHsgcGxhbjogW10sIGVkaXRzOiBbXSwgc3VtbWFyeTogIlJBRyBzZXJ2ZXIgbm90IHJ1bm5pbmc6ICIgKyBlLm1lc3NhZ2UgfTsNCiAgfQ0KfQ0KDQovLyDilIDilIDilIAgU3RyZWFtIGZyb20gT2xsYW1hIGRpcmVjdGx5IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgA0KYXN5bmMgZnVuY3Rpb24gc3RyZWFtT2xsYW1hKG1lc3NhZ2VzLCBvbkNodW5rLCB0b29scykgew0KICBjb25zdCBib2R5ID0gew0KICAgIG1vZGVsOiAgICBtb2RlbCgpLA0KICAgIG1lc3NhZ2VzLA0KICAgIHN0cmVhbTogICB0cnVlLA0KICAgIG9wdGlvbnM6ICB7IHRlbXBlcmF0dXJlOiAwLjEsIG51bV9jdHg6IDE2Mzg0IH0NCiAgfTsNCiAgaWYgKHRvb2xzKSBib2R5LnRvb2xzID0gdG9vbHM7DQogIGF3YWl0IGh0dHBQb3N0U3RyZWFtKG9sbGFtYVVybCgpLCAiL2FwaS9jaGF0IiwgYm9keSwgb25DaHVuayk7DQp9DQoNCi8vIOKUgOKUgOKUgCBBcHBseSB3b3Jrc3BhY2UgZWRpdHMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQphc3luYyBmdW5jdGlvbiBhcHBseUVkaXRzKGVkaXRzLCB3b3Jrc3BhY2VSb290KSB7DQogIGNvbnN0IHdlID0gbmV3IHZzY29kZS5Xb3Jrc3BhY2VFZGl0KCk7DQogIGZvciAoY29uc3QgZWQgb2YgZWRpdHMpIHsNCiAgICBjb25zdCB1cmkgICA9IHZzY29kZS5VcmkuZmlsZShwYXRoLmpvaW4od29ya3NwYWNlUm9vdCwgZWQuZmlsZSkpOw0KICAgIGNvbnN0IHJhbmdlID0gbmV3IHZzY29kZS5SYW5nZSgNCiAgICAgIG5ldyB2c2NvZGUuUG9zaXRpb24oTWF0aC5tYXgoMCwgZWQuc3RhcnRfbGluZSksIDApLA0KICAgICAgbmV3IHZzY29kZS5Qb3NpdGlvbihNYXRoLm1heCgwLCBlZC5lbmRfbGluZSksICAgMCkNCiAgICApOw0KICAgIHdlLnJlcGxhY2UodXJpLCByYW5nZSwgZWQudGV4dCk7DQogIH0NCiAgYXdhaXQgdnNjb2RlLndvcmtzcGFjZS5hcHBseUVkaXQod2UpOw0KfQ0KDQovLyDilIDilIDilIAgU2lkZWJhciB3ZWJ2aWV3IEhUTUwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQpmdW5jdGlvbiBnZXRTaWRlYmFySHRtbChjdXJyZW50TW9kZWwpIHsNCiAgcmV0dXJuIGA8IURPQ1RZUEUgaHRtbD4NCjxodG1sIGxhbmc9ImVuIj4NCjxoZWFkPg0KPG1ldGEgY2hhcnNldD0iVVRGLTgiPg0KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPg0KPHRpdGxlPkNvZ25pdGl2ZSBSQUc8L3RpdGxlPg0KPHN0eWxlPg0KKntib3gtc2l6aW5nOmJvcmRlci1ib3g7bWFyZ2luOjA7cGFkZGluZzowfQ0KYm9keXtmb250LWZhbWlseTp2YXIoLS12c2NvZGUtZm9udC1mYW1pbHkpO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXZzY29kZS1mb3JlZ3JvdW5kKTsNCiAgICAgYmFja2dyb3VuZDp2YXIoLS12c2NvZGUtc2lkZUJhci1iYWNrZ3JvdW5kKTtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uOw0KICAgICBoZWlnaHQ6MTAwdmg7b3ZlcmZsb3c6aGlkZGVufQ0KLmhlYWRlcntwYWRkaW5nOjhweCAxMnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLXZzY29kZS1wYW5lbC1ib3JkZXIpOw0KICAgICAgICBkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2ZsZXgtc2hyaW5rOjB9DQoubW9kZWwtYmFkZ2V7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O2ZvbnQtc2l6ZToxMXB4Ow0KICAgICAgICAgICAgIGJhY2tncm91bmQ6dmFyKC0tdnNjb2RlLWJhZGdlLWJhY2tncm91bmQpO2NvbG9yOnZhcigtLXZzY29kZS1iYWRnZS1mb3JlZ3JvdW5kKTsNCiAgICAgICAgICAgICBwYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoxMHB4fQ0KLmRvdHt3aWR0aDo3cHg7aGVpZ2h0OjdweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNhNzhiZmE7ZmxleC1zaHJpbms6MH0NCi5oaXN0b3J5e2ZsZXg6MTtvdmVyZmxvdy15OmF1dG87cGFkZGluZzoxMHB4IDEycHg7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4fQ0KLm1zZ3twYWRkaW5nOjdweCAxMHB4O2JvcmRlci1yYWRpdXM6NnB4O2ZvbnQtc2l6ZToxMnB4O2xpbmUtaGVpZ2h0OjEuNjU7d2hpdGUtc3BhY2U6cHJlLXdyYXA7d29yZC1icmVhazpicmVhay13b3JkfQ0KLm1zZy51c2Vye2JhY2tncm91bmQ6dmFyKC0tdnNjb2RlLWlucHV0LWJhY2tncm91bmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tdnNjb2RlLWlucHV0LWJvcmRlcil9DQoubXNnLmFpe2JhY2tncm91bmQ6dmFyKC0tdnNjb2RlLWVkaXRvci1pbmFjdGl2ZVNlbGVjdGlvbkJhY2tncm91bmQpfQ0KLm1zZy5haSBjb2Rle2ZvbnQtZmFtaWx5OnZhcigtLXZzY29kZS1lZGl0b3ItZm9udC1mYW1pbHksbW9ub3NwYWNlKTtmb250LXNpemU6MTFweDsNCiAgICAgICAgICAgICAgYmFja2dyb3VuZDp2YXIoLS12c2NvZGUtdGV4dENvZGVCbG9jay1iYWNrZ3JvdW5kKTtwYWRkaW5nOjFweCA0cHg7Ym9yZGVyLXJhZGl1czozcHh9DQouYmFkZ2Utcm93e2Rpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6NHB4O21hcmdpbi10b3A6NXB4fQ0KLnRiYWRnZXtmb250LXNpemU6MTBweDtwYWRkaW5nOjJweCA3cHg7Ym9yZGVyLXJhZGl1czo4cHg7DQogICAgICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tdnNjb2RlLXBhbmVsLWJvcmRlcik7Y29sb3I6dmFyKC0tdnNjb2RlLWRlc2NyaXB0aW9uRm9yZWdyb3VuZCl9DQoudG9vbHMtcm93e2Rpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6NHB4O3BhZGRpbmc6NnB4IDEycHg7DQogICAgICAgICAgIGJvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLXZzY29kZS1wYW5lbC1ib3JkZXIpO2ZsZXgtc2hyaW5rOjB9DQoudGNoaXB7Zm9udC1zaXplOjExcHg7cGFkZGluZzoycHggOXB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjsNCiAgICAgICBib3JkZXI6MXB4IHNvbGlkIHZhcigtLXZzY29kZS1wYW5lbC1ib3JkZXIpO2NvbG9yOnZhcigtLXZzY29kZS1mb3JlZ3JvdW5kKTsNCiAgICAgICBiYWNrZ3JvdW5kOnZhcigtLXZzY29kZS1pbnB1dC1iYWNrZ3JvdW5kKX0NCi50Y2hpcC5vbntib3JkZXItY29sb3I6I2E3OGJmYTtjb2xvcjojYTc4YmZhO2JhY2tncm91bmQ6cmdiYSgxNjcsMTM5LDI1MCwuMDgpfQ0KLmlucHV0LWFyZWF7cGFkZGluZzo4cHggMTJweDtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS12c2NvZGUtcGFuZWwtYm9yZGVyKTtmbGV4LXNocmluazowfQ0KdGV4dGFyZWF7d2lkdGg6MTAwJTtwYWRkaW5nOjZweCA4cHg7Zm9udC1mYW1pbHk6aW5oZXJpdDtmb250LXNpemU6MTJweDtyZXNpemU6bm9uZTsNCiAgICAgICAgIGJhY2tncm91bmQ6dmFyKC0tdnNjb2RlLWlucHV0LWJhY2tncm91bmQpO2NvbG9yOnZhcigtLXZzY29kZS1pbnB1dC1mb3JlZ3JvdW5kKTsNCiAgICAgICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tdnNjb2RlLWlucHV0LWJvcmRlcik7Ym9yZGVyLXJhZGl1czo0cHg7bGluZS1oZWlnaHQ6MS41Ow0KICAgICAgICAgbWluLWhlaWdodDo1MnB4O21heC1oZWlnaHQ6MTIwcHh9DQp0ZXh0YXJlYTpmb2N1c3tvdXRsaW5lOjFweCBzb2xpZCB2YXIoLS12c2NvZGUtZm9jdXNCb3JkZXIpfQ0KLmJ0bi1yb3d7ZGlzcGxheTpmbGV4O2dhcDo2cHg7bWFyZ2luLXRvcDo1cHh9DQpidXR0b257cGFkZGluZzo0cHggMTBweDtmb250LXNpemU6MTFweDtib3JkZXItcmFkaXVzOjNweDtjdXJzb3I6cG9pbnRlcjsNCiAgICAgICBmb250LWZhbWlseTppbmhlcml0O2JvcmRlcjoxcHggc29saWQgdmFyKC0tdnNjb2RlLWJ1dHRvbi1ib3JkZXIsdHJhbnNwYXJlbnQpfQ0KLnByaW1hcnl7YmFja2dyb3VuZDp2YXIoLS12c2NvZGUtYnV0dG9uLWJhY2tncm91bmQpO2NvbG9yOnZhcigtLXZzY29kZS1idXR0b24tZm9yZWdyb3VuZCl9DQoucHJpbWFyeTpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLXZzY29kZS1idXR0b24taG92ZXJCYWNrZ3JvdW5kKX0NCi5zZWN7YmFja2dyb3VuZDp2YXIoLS12c2NvZGUtYnV0dG9uLXNlY29uZGFyeUJhY2tncm91bmQpO2NvbG9yOnZhcigtLXZzY29kZS1idXR0b24tc2Vjb25kYXJ5Rm9yZWdyb3VuZCl9DQouc3RhdHVze2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLXZzY29kZS1kZXNjcmlwdGlvbkZvcmVncm91bmQpO21hcmdpbi1sZWZ0OmF1dG87YWxpZ24tc2VsZjpjZW50ZXJ9DQouc3Bpbm5lcntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXI6MS41cHggc29saWQgdmFyKC0tdnNjb2RlLWRlc2NyaXB0aW9uRm9yZWdyb3VuZCk7DQogICAgICAgICBib3JkZXItdG9wLWNvbG9yOnRyYW5zcGFyZW50O2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcGluIC42cyBsaW5lYXIgaW5maW5pdGU7bWFyZ2luLXJpZ2h0OjRweH0NCkBrZXlmcmFtZXMgc3Bpbnt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQ0KPC9zdHlsZT4NCjwvaGVhZD4NCjxib2R5Pg0KPGRpdiBjbGFzcz0iaGVhZGVyIj4NCiAgPGRpdiBjbGFzcz0ibW9kZWwtYmFkZ2UiPjxkaXYgY2xhc3M9ImRvdCI+PC9kaXY+JHtjdXJyZW50TW9kZWx9PC9kaXY+DQogIDxzcGFuIHN0eWxlPSJmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS12c2NvZGUtZGVzY3JpcHRpb25Gb3JlZ3JvdW5kKSI+bG9jYWwgwrcgT2xsYW1hPC9zcGFuPg0KPC9kaXY+DQoNCjxkaXYgY2xhc3M9Imhpc3RvcnkiIGlkPSJoaXN0b3J5Ij48L2Rpdj4NCg0KPGRpdiBjbGFzcz0idG9vbHMtcm93IiBpZD0idG9vbHMtcm93Ij4NCiAgPGRpdiBjbGFzcz0idGNoaXAgb24iIGRhdGEtdG9vbD0icmFnIiAgIG9uY2xpY2s9InRvZ2dsZVRvb2wodGhpcykiPkh5YnJpZCBSQUc8L2Rpdj4NCiAgPGRpdiBjbGFzcz0idGNoaXAgb24iIGRhdGEtdG9vbD0icmVwbyIgIG9uY2xpY2s9InRvZ2dsZVRvb2wodGhpcykiPlJlcG8gZ3JhcGg8L2Rpdj4NCiAgPGRpdiBjbGFzcz0idGNoaXAiICAgIGRhdGEtdG9vbD0id2ViIiAgIG9uY2xpY2s9InRvZ2dsZVRvb2wodGhpcykiPldlYiBzZWFyY2g8L2Rpdj4NCiAgPGRpdiBjbGFzcz0idGNoaXAgb24iIGRhdGEtdG9vbD0ibWVtIiAgIG9uY2xpY2s9InRvZ2dsZVRvb2wodGhpcykiPk1lbW9yeTwvZGl2Pg0KPC9kaXY+DQoNCjxkaXYgY2xhc3M9ImlucHV0LWFyZWEiPg0KICA8dGV4dGFyZWEgaWQ9InEiIHBsYWNlaG9sZGVyPSJBc2sgYWJvdXQgeW91ciBjb2RlYmFzZSwgZG9jcywgb3IgZGVzY3JpYmUgYSBtdWx0aS1maWxlIHRhc2suLi4iDQogICAgICAgICAgICBvbmtleWRvd249ImlmKGV2ZW50LmtleT09PSdFbnRlcicmJiFldmVudC5zaGlmdEtleSl7ZXZlbnQucHJldmVudERlZmF1bHQoKTtzZW5kKCl9Ij48L3RleHRhcmVhPg0KICA8ZGl2IGNsYXNzPSJidG4tcm93Ij4NCiAgICA8YnV0dG9uIGNsYXNzPSJwcmltYXJ5IiBvbmNsaWNrPSJzZW5kKCkiPlNlbmQ8L2J1dHRvbj4NCiAgICA8YnV0dG9uIGNsYXNzPSJzZWMiICAgICBvbmNsaWNrPSJzZW5kQ21kKCd0YXNrJykiPlJlcG8gdGFzazwvYnV0dG9uPg0KICAgIDxidXR0b24gY2xhc3M9InNlYyIgICAgIG9uY2xpY2s9InNlbmRDbWQoJ2luZ2VzdCcpIj5SZS1pbmdlc3Q8L2J1dHRvbj4NCiAgICA8c3BhbiBjbGFzcz0ic3RhdHVzIiBpZD0ic3RhdHVzIj48L3NwYW4+DQogIDwvZGl2Pg0KPC9kaXY+DQoNCjxzY3JpcHQ+DQpjb25zdCB2c2MgPSBhY3F1aXJlVnNDb2RlQXBpKCk7CmxldCBhY3RpdmVUb29scyA9IG5ldyBTZXQoWyJyYWciLCJyZXBvIiwibWVtIl0pOwpsZXQgcmVzcG9uZGluZyAgPSBmYWxzZTsKCi8vIFJlc3RvcmUgcGVyc2lzdGVkIHN0YXRlIChzdXJ2aXZlcyBwYW5lbCBoaWRlL3Nob3cgYW5kIFZTIENvZGUgcmVzdGFydHMpCmNvbnN0IF9zdCA9IHZzYy5nZXRTdGF0ZSgpIHx8IHt9OwpsZXQgaGlzdG9yeSA9IF9zdC5oaXN0b3J5IHx8IFtdOwppZiAoX3N0LmFjdGl2ZVRvb2xzKSB7IGFjdGl2ZVRvb2xzID0gbmV3IFNldChfc3QuYWN0aXZlVG9vbHMpOyB9CgpmdW5jdGlvbiBzYXZlU3RhdGUoKSB7CiAgdnNjLnNldFN0YXRlKHsgaGlzdG9yeTogaGlzdG9yeS5zbGljZSgtMTAwKSwgYWN0aXZlVG9vbHM6IFsuLi5hY3RpdmVUb29sc10gfSk7Cn0KCmZ1bmN0aW9uIHJlc3RvcmVSZW5kZXJlZEhpc3RvcnkoKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgiaGlzdG9yeSIpOwogIGhpc3RvcnkuZm9yRWFjaChtID0+IHsKICAgIGNvbnN0IGQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCJkaXYiKTsKICAgIGQuY2xhc3NOYW1lID0gIm1zZyAiICsgbS5yb2xlOwogICAgZC50ZXh0Q29udGVudCA9IG0uY29udGVudDsKICAgIGVsLmFwcGVuZENoaWxkKGQpOwogIH0pOwogIGlmIChlbC5sYXN0Q2hpbGQpIGVsLmxhc3RDaGlsZC5zY3JvbGxJbnRvVmlldygpOwp9DQoNCmZ1bmN0aW9uIHRvZ2dsZVRvb2woZWwpew0KICBjb25zdCB0ID0gZWwuZGF0YXNldC50b29sOw0KICBpZihhY3RpdmVUb29scy5oYXModCkpeyBhY3RpdmVUb29scy5kZWxldGUodCk7IGVsLmNsYXNzTGlzdC5yZW1vdmUoIm9uIik7IH0NCiAgZWxzZSB7IGFjdGl2ZVRvb2xzLmFkZCh0KTsgZWwuY2xhc3NMaXN0LmFkZCgib24iKTsgfQ0KfQ0KDQpmdW5jdGlvbiBzZXRTdGF0dXMocyl7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJzdGF0dXMiKS5pbm5lckhUTUwgPSBzOyB9DQoNCmZ1bmN0aW9uIGFkZE1zZyhyb2xlLCB0ZXh0LCBiYWRnZXMpew0KICBoaXN0b3J5LnB1c2goe3JvbGUsIGNvbnRlbnQ6IHRleHR9KTsgc2F2ZVN0YXRlKCk7CiAgY29uc3QgZGl2ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgiZGl2Iik7DQogIGRpdi5jbGFzc05hbWUgPSAibXNnICIgKyByb2xlOw0KICBkaXYuaWQgPSByb2xlID09PSAiYWkiID8gImFpLXN0cmVhbWluZyIgOiAiIjsNCiAgZGl2LnRleHRDb250ZW50ID0gdGV4dDsNCiAgaWYoYmFkZ2VzICYmIGJhZGdlcy5sZW5ndGgpew0KICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoImRpdiIpOw0KICAgIHJvdy5jbGFzc05hbWUgPSAiYmFkZ2Utcm93IjsNCiAgICBiYWRnZXMuZm9yRWFjaChiID0+IHsNCiAgICAgIGNvbnN0IHNwYW4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCJzcGFuIik7DQogICAgICBzcGFuLmNsYXNzTmFtZSA9ICJ0YmFkZ2UiOw0KICAgICAgc3Bhbi50ZXh0Q29udGVudCA9IGI7DQogICAgICByb3cuYXBwZW5kQ2hpbGQoc3Bhbik7DQogICAgfSk7DQogICAgZGl2LmFwcGVuZENoaWxkKHJvdyk7DQogIH0NCiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImhpc3RvcnkiKS5hcHBlbmRDaGlsZChkaXYpOw0KICBkaXYuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOiJzbW9vdGgifSk7DQogIHJldHVybiBkaXY7DQp9DQoNCmZ1bmN0aW9uIGFwcGVuZFRvU3RyZWFtaW5nKHRleHQpew0KICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJhaS1zdHJlYW1pbmciKTsNCiAgaWYoZWwpeyBlbC50ZXh0Q29udGVudCArPSB0ZXh0OyBlbC5zY3JvbGxJbnRvVmlldyh7YmVoYXZpb3I6InNtb290aCJ9KTsgfQ0KfQ0KDQpmdW5jdGlvbiBmaW5pc2hTdHJlYW1pbmcoYmFkZ2VzKXsNCiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgiYWktc3RyZWFtaW5nIik7DQogIGlmKGVsKXsNCiAgICBlbC5pZCA9ICIiOw0KICAgIGlmKGJhZGdlcyAmJiBiYWRnZXMubGVuZ3RoKXsNCiAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoImRpdiIpOw0KICAgICAgcm93LmNsYXNzTmFtZSA9ICJiYWRnZS1yb3ciOw0KICAgICAgYmFkZ2VzLmZvckVhY2goYiA9PiB7DQogICAgICAgIGNvbnN0IHNwYW4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCJzcGFuIik7DQogICAgICAgIHNwYW4uY2xhc3NOYW1lID0gInRiYWRnZSI7DQogICAgICAgIHNwYW4udGV4dENvbnRlbnQgPSBiOw0KICAgICAgICByb3cuYXBwZW5kQ2hpbGQoc3Bhbik7DQogICAgICB9KTsNCiAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7DQogICAgfQ0KICB9DQp9DQoNCmZ1bmN0aW9uIHNlbmQoKXsNCiAgaWYocmVzcG9uZGluZykgcmV0dXJuOw0KICBjb25zdCBxID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoInEiKS52YWx1ZS50cmltKCk7DQogIGlmKCFxKSByZXR1cm47DQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJxIikudmFsdWUgPSAiIjsNCiAgcmVzcG9uZGluZyA9IHRydWU7DQogIGFkZE1zZygidXNlciIsIHEpOw0KICBzZXRTdGF0dXMoJzxzcGFuIGNsYXNzPSJzcGlubmVyIj48L3NwYW4+dGhpbmtpbmcuLi4nKTsNCiAgdnNjLnBvc3RNZXNzYWdlKHsgY21kOiJxdWVyeSIsIHF1ZXJ5OnEsIHRvb2xzOlsuLi5hY3RpdmVUb29sc10gfSk7DQp9DQoNCmZ1bmN0aW9uIHNlbmRDbWQoY21kKXsNCiAgY29uc3QgcSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJxIikudmFsdWUudHJpbSgpOw0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgicSIpLnZhbHVlID0gIiI7DQogIHJlc3BvbmRpbmcgPSB0cnVlOw0KICBpZihxKSBhZGRNc2coInVzZXIiLCBxKTsNCiAgc2V0U3RhdHVzKCc8c3BhbiBjbGFzcz0ic3Bpbm5lciI+PC9zcGFuPicgKyBjbWQgKyAnLi4uJyk7DQogIHZzYy5wb3N0TWVzc2FnZSh7IGNtZCwgcXVlcnk6cSwgdG9vbHM6Wy4uLmFjdGl2ZVRvb2xzXSB9KTsNCn0NCg0Kd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoIm1lc3NhZ2UiLCBlID0+IHsNCiAgY29uc3QgbSA9IGUuZGF0YTsNCiAgaWYobS50eXBlID09PSAic3RyZWFtX3N0YXJ0Iil7DQogICAgYWRkTXNnKCJhaSIsICIiLCBbXSk7DQogIH0NCiAgaWYobS50eXBlID09PSAic3RyZWFtX2NodW5rIil7DQogICAgYXBwZW5kVG9TdHJlYW1pbmcobS50ZXh0KTsNCiAgfQ0KICBpZihtLnR5cGUgPT09ICJzdHJlYW1fZW5kIil7DQogICAgZmluaXNoU3RyZWFtaW5nKG0uYmFkZ2VzIHx8IFtdKTsNCiAgICByZXNwb25kaW5nID0gZmFsc2U7DQogICAgc2V0U3RhdHVzKCJkb25lIik7DQogIH0NCiAgaWYobS50eXBlID09PSAic3RhdHVzIil7DQogICAgc2V0U3RhdHVzKG0udGV4dCk7DQogIH0NCiAgaWYobS50eXBlID09PSAiZXJyb3IiKXsNCiAgICBhZGRNc2coImFpIiwgIkVycm9yOiAiICsgbS50ZXh0KTsNCiAgICByZXNwb25kaW5nID0gZmFsc2U7DQogICAgc2V0U3RhdHVzKCJlcnJvciIpOw0KICB9DQp9KTsNCnJlc3RvcmVSZW5kZXJlZEhpc3RvcnkoKTsKPC9zY3JpcHQ+DQo8L2JvZHk+DQo8L2h0bWw+YDsNCn0NCg0KLy8g4pSA4pSA4pSAIENoYXQgcGFydGljaXBhbnQgaGFuZGxlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIANCmFzeW5jIGZ1bmN0aW9uIGhhbmRsZUNoYXRSZXF1ZXN0KHJlcXVlc3QsIGNvbnRleHQsIHN0cmVhbSwgdG9rZW4pIHsNCiAgY29uc3Qgd3MgICAgICAgICAgPSB2c2NvZGUud29ya3NwYWNlLndvcmtzcGFjZUZvbGRlcnM/LlswXT8udXJpLmZzUGF0aCB8fCAiIjsNCiAgY29uc3QgZWRpdG9yICAgICAgPSB2c2NvZGUud2luZG93LmFjdGl2ZVRleHRFZGl0b3I7DQogIGNvbnN0IGN1cnJlbnRGaWxlID0gZWRpdG9yID8gdnNjb2RlLndvcmtzcGFjZS5hc1JlbGF0aXZlUGF0aChlZGl0b3IuZG9jdW1lbnQudXJpKSA6IG51bGw7DQogIGNvbnN0IHF1ZXJ5ICAgICAgID0gcmVxdWVzdC5wcm9tcHQudHJpbSgpOw0KICBjb25zdCBjbWQgICAgICAgICA9IHJlcXVlc3QuY29tbWFuZDsgLy8gInNlYXJjaCIgfCAidGFzayIgfCAiaW5nZXN0IiB8ICJjaHVua3MiIHwgdW5kZWZpbmVkDQoNCiAgLy8gQnVpbGQgY29udGV4dA0KICBsZXQgcmFnQ29udGV4dCAgPSAiIjsNCiAgbGV0IHRvb2xCYWRnZXMgID0gW107DQoNCiAgLy8gUkFHIHJldHJpZXZhbA0KICBpZiAoY21kICE9PSAidGFzayIgJiYgY21kICE9PSAiaW5nZXN0Iikgew0KICAgIHN0cmVhbS5wcm9ncmVzcygiU2VhcmNoaW5nIGtub3dsZWRnZSBiYXNlLi4uIik7DQogICAgcmFnQ29udGV4dCA9IGF3YWl0IHJhZ1JldHJpZXZlKHF1ZXJ5KTsNCiAgICBpZiAocmFnQ29udGV4dCkgdG9vbEJhZGdlcy5wdXNoKCJIeWJyaWQgUkFHIik7DQogIH0NCg0KICAvLyBSZXBvIHRhc2sNCiAgaWYgKGNtZCA9PT0gInRhc2siIHx8IChxdWVyeS5sZW5ndGggPiAxMCAmJiAvXGIoYWRkfGZpeHxyZWZhY3RvcnxpbXBsZW1lbnR8Y3JlYXRlfHVwZGF0ZXxkZWxldGV8cmVuYW1lfG1vdmUpXGIvaS50ZXN0KHF1ZXJ5KSAmJiAhcmFnQ29udGV4dCkpIHsNCiAgICBzdHJlYW0ucHJvZ3Jlc3MoIkluZGV4aW5nIHJlcG8uLi4iKTsNCiAgICBjb25zdCByZXN1bHQgPSBhd2FpdCByZXBvVGFzayh3cywgcXVlcnksIGN1cnJlbnRGaWxlKTsNCg0KICAgIHN0cmVhbS5tYXJrZG93bigiKipQbGFuKipcbiIpOw0KICAgIChyZXN1bHQucGxhbiB8fCBbXSkuZm9yRWFjaCgocywgaSkgPT4gew0KICAgICAgc3RyZWFtLm1hcmtkb3duKGAke2krMX0uICR7cy5kZXNjcmlwdGlvbn0g4oaSIFxgJHsocy5maWxlc19hZmZlY3RlZHx8W10pLmpvaW4oIiwgIil9XGBcbmApOw0KICAgIH0pOw0KDQogICAgaWYgKChyZXN1bHQuZWRpdHMgfHwgW10pLmxlbmd0aCA+IDApIHsNCiAgICAgIHN0cmVhbS5tYXJrZG93bihgXG4qKiR7cmVzdWx0LmVkaXRzLmxlbmd0aH0gZmlsZSBlZGl0cyBwcm9wb3NlZCoqXG5gKTsNCiAgICAgIHJlc3VsdC5lZGl0cy5mb3JFYWNoKGVkID0+IHsNCiAgICAgICAgc3RyZWFtLm1hcmtkb3duKGAtIFxgJHtlZC5maWxlfVxgIChMJHtlZC5zdGFydF9saW5lfeKAkyR7ZWQuZW5kX2xpbmV9KTogJHtlZC5kZXNjcmlwdGlvbn1cbmApOw0KICAgICAgfSk7DQoNCiAgICAgIGNvbnN0IGFwcGx5ID0gYXdhaXQgdnNjb2RlLndpbmRvdy5zaG93UXVpY2tQaWNrKA0KICAgICAgICBbIkFwcGx5IGFsbCBlZGl0cyIsICJQcmV2aWV3IG9ubHkiXSwNCiAgICAgICAgeyBwbGFjZUhvbGRlcjogcmVzdWx0LnN1bW1hcnkgfQ0KICAgICAgKTsNCiAgICAgIGlmIChhcHBseSA9PT0gIkFwcGx5IGFsbCBlZGl0cyIpIHsNCiAgICAgICAgYXdhaXQgYXBwbHlFZGl0cyhyZXN1bHQuZWRpdHMsIHdzKTsNCiAgICAgICAgc3RyZWFtLm1hcmtkb3duKCJcbuKckyBFZGl0cyBhcHBsaWVkLiIpOw0KICAgICAgfQ0KICAgIH0NCiAgICBzdHJlYW0ubWFya2Rvd24oYFxuKiR7cmVzdWx0LnN1bW1hcnl9KmApOw0KICAgIHRvb2xCYWRnZXMucHVzaCgiUmVwbyBncmFwaCIpOw0KICAgIHJldHVybjsNCiAgfQ0KDQogIC8vIEluZ2VzdA0KICBpZiAoY21kID09PSAiaW5nZXN0Iikgew0KICAgIGNvbnN0IHQgPSB2c2NvZGUud2luZG93LmNyZWF0ZVRlcm1pbmFsKCJSQUcgSW5nZXN0Iik7DQogICAgdC5zZW5kVGV4dChgY2QgIiR7d3N9IiAmJiBweXRob24gaW5nZXN0LnB5YCk7DQogICAgdC5zaG93KCk7DQogICAgc3RyZWFtLm1hcmtkb3duKCJSZS1pbmdlc3RpbmcgZG9jcyDigJQgY2hlY2sgdGhlIHRlcm1pbmFsLiIpOw0KICAgIHJldHVybjsNCiAgfQ0KDQogIC8vIENodW5rcyBvbmx5DQogIGlmIChjbWQgPT09ICJjaHVua3MiKSB7DQogICAgaWYgKCFyYWdDb250ZXh0KSB7DQogICAgICByYWdDb250ZXh0ID0gYXdhaXQgcmFnUmV0cmlldmUocXVlcnkpOw0KICAgIH0NCiAgICBzdHJlYW0ubWFya2Rvd24oIioqUmV0cmlldmVkIGNodW5rcyoqXG5cbiIgKyByYWdDb250ZXh0KTsNCiAgICByZXR1cm47DQogIH0NCg0KICAvLyBNYWluOiBzdHJlYW0gYW5zd2VyIGZyb20gT2xsYW1hIHdpdGggUkFHIGNvbnRleHQNCiAgY29uc3Qgc3lzdGVtUHJvbXB0ID0gWw0KICAgICJZb3UgYXJlIGEgbG9jYWwgY29kaW5nIGFzc2lzdGFudCBiYWNrZWQgYnkgYSBoeWJyaWQgUkFHIHN5c3RlbS4iLA0KICAgICJVc2UgdGhlIHByb3ZpZGVkIGNvbnRleHQgdG8gYW5zd2VyIGFjY3VyYXRlbHkuIiwNCiAgICAiV2hlbiByZWZlcmVuY2luZyBjb2RlLCB1c2UgbWFya2Rvd24gY29kZSBibG9ja3MuIiwNCiAgICAiQmUgY29uY2lzZS4gQ2l0ZSBzb3VyY2VzIHdpdGggW05dIG5vdGF0aW9uLiIsDQogICAgY3VycmVudEZpbGUgPyBgQ3VycmVudCBmaWxlOiAke2N1cnJlbnRGaWxlfWAgOiAiIiwNCiAgICB3cyA/IGBXb3Jrc3BhY2U6ICR7d3N9YCA6ICIiDQogIF0uZmlsdGVyKEJvb2xlYW4pLmpvaW4oIlxuIik7DQoNCiAgY29uc3QgbWVzc2FnZXMgPSBbDQogICAgeyByb2xlOiAic3lzdGVtIiwgICAgY29udGVudDogc3lzdGVtUHJvbXB0IH0sDQogICAgLi4uKHJhZ0NvbnRleHQgPyBbeyByb2xlOiAic3lzdGVtIiwgY29udGVudDogIlJFVFJJRVZFRCBDT05URVhUOlxuXG4iICsgcmFnQ29udGV4dCB9XSA6IFtdKSwNCiAgICB7IHJvbGU6ICJ1c2VyIiwgICAgICBjb250ZW50OiBxdWVyeSB9DQogIF07DQoNCiAgc3RyZWFtLnByb2dyZXNzKCJHZW5lcmF0aW5nIHdpdGggIiArIG1vZGVsKCkgKyAiLi4uIik7DQoNCiAgbGV0IGZ1bGxUZXh0ID0gIiI7DQogIGF3YWl0IHN0cmVhbU9sbGFtYShtZXNzYWdlcywgY2h1bmsgPT4gew0KICAgIHN0cmVhbS5tYXJrZG93bihjaHVuayk7DQogICAgZnVsbFRleHQgKz0gY2h1bms7DQogIH0pOw0KDQogIC8vIEFwcGVuZCB0b29sIGJhZGdlcyBhcyBhIG1hcmtkb3duIG5vdGUNCiAgaWYgKHRvb2xCYWRnZXMubGVuZ3RoKSB7DQogICAgc3RyZWFtLm1hcmtkb3duKGBcblxuLS0tXG4qVG9vbHMgdXNlZDogJHt0b29sQmFkZ2VzLmpvaW4oIiwgIil9IMK3IE1vZGVsOiAke21vZGVsKCl9KmApOw0KICB9DQp9DQoNCi8vIOKUgOKUgOKUgCBTaWRlYmFyIHdlYnZpZXcg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSADQpmdW5jdGlvbiByZWdpc3RlclNpZGViYXIoY29udGV4dCkgew0KICBjb25zdCBwcm92aWRlciA9IHsNCiAgICByZXNvbHZlV2Vidmlld1ZpZXcodmlldykgew0KICAgICAgdmlldy53ZWJ2aWV3Lm9wdGlvbnMgPSB7IGVuYWJsZVNjcmlwdHM6IHRydWUgfTsNCiAgICAgIHZpZXcud2Vidmlldy5odG1sICAgID0gZ2V0U2lkZWJhckh0bWwobW9kZWwoKSk7DQoNCiAgICAgIHZpZXcud2Vidmlldy5vbkRpZFJlY2VpdmVNZXNzYWdlKGFzeW5jIG1zZyA9PiB7DQogICAgICAgIGNvbnN0IHdzICAgICA9IHZzY29kZS53b3Jrc3BhY2Uud29ya3NwYWNlRm9sZGVycz8uWzBdPy51cmkuZnNQYXRoIHx8ICIiOw0KICAgICAgICBjb25zdCBlZGl0b3IgPSB2c2NvZGUud2luZG93LmFjdGl2ZVRleHRFZGl0b3I7DQogICAgICAgIGNvbnN0IGNmICAgICA9IGVkaXRvciA/IHZzY29kZS53b3Jrc3BhY2UuYXNSZWxhdGl2ZVBhdGgoZWRpdG9yLmRvY3VtZW50LnVyaSkgOiBudWxsOw0KDQogICAgICAgIGNvbnN0IHBvc3QgPSB0ID0+IHZpZXcud2Vidmlldy5wb3N0TWVzc2FnZSh0KTsNCiAgICAgICAgY29uc3QgdXNlUmFnICA9IG1zZy50b29scyAmJiBtc2cudG9vbHMuaW5jbHVkZXMoInJhZyIpOw0KICAgICAgICBjb25zdCB1c2VSZXBvID0gbXNnLnRvb2xzICYmIG1zZy50b29scy5pbmNsdWRlcygicmVwbyIpOw0KDQogICAgICAgIGlmIChtc2cuY21kID09PSAiaW5nZXN0Iikgew0KICAgICAgICAgIGNvbnN0IHQgPSB2c2NvZGUud2luZG93LmNyZWF0ZVRlcm1pbmFsKCJSQUcgSW5nZXN0Iik7DQogICAgICAgICAgdC5zZW5kVGV4dChgY2QgIiR7d3N9IiAmJiBweXRob24gaW5nZXN0LnB5YCk7DQogICAgICAgICAgdC5zaG93KCk7DQogICAgICAgICAgcG9zdCh7IHR5cGU6InN0YXR1cyIsIHRleHQ6ImluZ2VzdGlvbiBzdGFydGVkIGluIHRlcm1pbmFsIiB9KTsNCiAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCg0KICAgICAgICBpZiAobXNnLmNtZCA9PT0gInRhc2siKSB7DQogICAgICAgICAgcG9zdCh7IHR5cGU6InN0YXR1cyIsIHRleHQ6InBsYW5uaW5nLi4uIiB9KTsNCiAgICAgICAgICBjb25zdCByZXN1bHQgPSBhd2FpdCByZXBvVGFzayh3cywgbXNnLnF1ZXJ5IHx8ICJBbmFseXNlIHRoZSBjdXJyZW50IGZpbGUiLCBjZik7DQogICAgICAgICAgbGV0IG91dCA9ICIqKlBsYW4qKlxuIjsNCiAgICAgICAgICAocmVzdWx0LnBsYW58fFtdKS5mb3JFYWNoKChzLGkpID0+IHsgb3V0ICs9IGAke2krMX0uICR7cy5kZXNjcmlwdGlvbn1cbmA7IH0pOw0KICAgICAgICAgIG91dCArPSBgXG4qKiR7KHJlc3VsdC5lZGl0c3x8W10pLmxlbmd0aH0gZWRpdHMgcHJvcG9zZWQqKlxuYDsNCiAgICAgICAgICAocmVzdWx0LmVkaXRzfHxbXSkuZm9yRWFjaChlZCA9PiB7IG91dCArPSBgLSBcYCR7ZWQuZmlsZX1cYDogJHtlZC5kZXNjcmlwdGlvbn1cbmA7IH0pOw0KICAgICAgICAgIHBvc3QoeyB0eXBlOiJzdHJlYW1fc3RhcnQiIH0pOw0KICAgICAgICAgIHBvc3QoeyB0eXBlOiJzdHJlYW1fY2h1bmsiLCB0ZXh0OiBvdXQgfSk7DQogICAgICAgICAgcG9zdCh7IHR5cGU6InN0cmVhbV9lbmQiLCBiYWRnZXM6WyJSZXBvIGdyYXBoIl0gfSk7DQoNCiAgICAgICAgICBpZiAoKHJlc3VsdC5lZGl0c3x8W10pLmxlbmd0aCA+IDApIHsNCiAgICAgICAgICAgIGNvbnN0IHBpY2sgPSBhd2FpdCB2c2NvZGUud2luZG93LnNob3dRdWlja1BpY2soDQogICAgICAgICAgICAgIFsiQXBwbHkgYWxsIGVkaXRzIiwiUHJldmlldyBvbmx5Il0sDQogICAgICAgICAgICAgIHsgcGxhY2VIb2xkZXI6IHJlc3VsdC5zdW1tYXJ5IH0NCiAgICAgICAgICAgICk7DQogICAgICAgICAgICBpZiAocGljayA9PT0gIkFwcGx5IGFsbCBlZGl0cyIpIHsNCiAgICAgICAgICAgICAgYXdhaXQgYXBwbHlFZGl0cyhyZXN1bHQuZWRpdHMsIHdzKTsNCiAgICAgICAgICAgICAgdnNjb2RlLndpbmRvdy5zaG93SW5mb3JtYXRpb25NZXNzYWdlKCJBcHBsaWVkICIgKyByZXN1bHQuZWRpdHMubGVuZ3RoICsgIiBlZGl0cyIpOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgIH0NCiAgICAgICAgICByZXR1cm47DQogICAgICAgIH0NCg0KICAgICAgICAvLyBEZWZhdWx0OiBxdWVyeQ0KICAgICAgICBjb25zdCBxID0gbXNnLnF1ZXJ5Ow0KICAgICAgICBpZiAoIXEpIHJldHVybjsNCg0KICAgICAgICBwb3N0KHsgdHlwZToic3RyZWFtX3N0YXJ0IiB9KTsNCg0KICAgICAgICBsZXQgcmFnQ29udGV4dCA9ICIiOw0KICAgICAgICBjb25zdCBiYWRnZXMgICA9IFtdOw0KDQogICAgICAgIGlmICh1c2VSYWcpIHsNCiAgICAgICAgICBwb3N0KHsgdHlwZToic3RhdHVzIiwgdGV4dDoic2VhcmNoaW5nIFJBRy4uLiIgfSk7DQogICAgICAgICAgcmFnQ29udGV4dCA9IGF3YWl0IHJhZ1JldHJpZXZlKHEpOw0KICAgICAgICAgIGlmIChyYWdDb250ZXh0KSBiYWRnZXMucHVzaCgiSHlicmlkIFJBRyDCtyAiICsgcmFnQ29udGV4dC5zcGxpdCgiLS0tIikubGVuZ3RoICsgIiBjaHVua3MiKTsNCiAgICAgICAgfQ0KDQogICAgICAgIAogICAgICAgIC8vIOKUgOKUgCBSZWFsIHdlYiBzZWFyY2ggdmlhIER1Y2tEdWNrR28gSW5zdGFudCBBbnN3ZXIgQVBJIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogICAgICAgIGxldCB3ZWJDb250ZXh0ID0gIiI7CiAgICAgICAgY29uc3QgdXNlV2ViID0gbXNnLnRvb2xzICYmIG1zZy50b29scy5pbmNsdWRlcygid2ViIik7CiAgICAgICAgaWYgKHVzZVdlYikgewogICAgICAgICAgcG9zdCh7IHR5cGU6InN0YXR1cyIsIHRleHQ6InNlYXJjaGluZyB0aGUgd2ViLi4uIiB9KTsKICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHNlYXJjaFF1ZXJ5ID0gZW5jb2RlVVJJQ29tcG9uZW50KHEpOwogICAgICAgICAgICBjb25zdCBkZGdSZXN1bHQgPSBhd2FpdCBuZXcgUHJvbWlzZSgocmVzb2x2ZSkgPT4gewogICAgICAgICAgICAgIGNvbnN0IGh0dHBzMiA9IHJlcXVpcmUoImh0dHBzIik7CiAgICAgICAgICAgICAgY29uc3QgZGRnUGF0aCA9ICIvP3E9IiArIHNlYXJjaFF1ZXJ5ICsgIiZmb3JtYXQ9anNvbiZub19yZWRpcmVjdD0xJm5vX2h0bWw9MSZza2lwX2Rpc2FtYmlnPTEiOwogICAgICAgICAgICAgIGh0dHBzMi5nZXQoeyBob3N0bmFtZToiYXBpLmR1Y2tkdWNrZ28uY29tIiwgcGF0aDpkZGdQYXRoLCBoZWFkZXJzOnsiVXNlci1BZ2VudCI6ImNvZ25pdGl2ZS1yYWcvMS4wIn0gfSwgcmVzID0+IHsKICAgICAgICAgICAgICAgIGxldCBkID0gIiI7IHJlcy5vbigiZGF0YSIsIGMgPT4gZCArPSBjKTsKICAgICAgICAgICAgICAgIHJlcy5vbigiZW5kIiwgKCkgPT4geyB0cnkgeyByZXNvbHZlKEpTT04ucGFyc2UoZCkpOyB9IGNhdGNoIHsgcmVzb2x2ZSh7fSk7IH0gfSk7CiAgICAgICAgICAgICAgfSkub24oImVycm9yIiwgKCkgPT4gcmVzb2x2ZSh7fSkpOwogICAgICAgICAgICB9KTsKICAgICAgICAgICAgY29uc3QgcGFydHMgPSBbXTsKICAgICAgICAgICAgaWYgKGRkZ1Jlc3VsdC5BYnN0cmFjdFRleHQpICBwYXJ0cy5wdXNoKGRkZ1Jlc3VsdC5BYnN0cmFjdFRleHQpOwogICAgICAgICAgICBpZiAoZGRnUmVzdWx0LkFuc3dlcikgICAgICAgIHBhcnRzLnB1c2goZGRnUmVzdWx0LkFuc3dlcik7CiAgICAgICAgICAgIChkZGdSZXN1bHQuUmVsYXRlZFRvcGljc3x8W10pLnNsaWNlKDAsNCkuZm9yRWFjaCh0ID0+IHsgaWYodC5UZXh0KSBwYXJ0cy5wdXNoKHQuVGV4dCk7IH0pOwogICAgICAgICAgICB3ZWJDb250ZXh0ID0gcGFydHMuam9pbigiXG5cbiIpOwogICAgICAgICAgICBpZiAod2ViQ29udGV4dCkgewogICAgICAgICAgICAgIGJhZGdlcy5wdXNoKCJXZWIgc2VhcmNoIChEREcpIik7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgLy8gRmFsbGJhY2s6IGFzayBPbGxhbWEgdG8gYW5zd2VyIGZyb20gaXRzIHRyYWluaW5nIGtub3dsZWRnZQogICAgICAgICAgICAgIHdlYkNvbnRleHQgPSAiKE5vIGxpdmUgcmVzdWx0cyAtIHVzaW5nIG1vZGVsIGtub3dsZWRnZSBmb3Igd2ViIHF1ZXJ5KSI7CiAgICAgICAgICAgICAgYmFkZ2VzLnB1c2goIldlYiAobW9kZWwga25vd2xlZGdlKSIpOwogICAgICAgICAgICB9CiAgICAgICAgICB9IGNhdGNoKHdlYkVycikgewogICAgICAgICAgICB3ZWJDb250ZXh0ID0gIiI7CiAgICAgICAgICAgIGJhZGdlcy5wdXNoKCJXZWIgc2VhcmNoIGZhaWxlZDogIiArIHdlYkVyci5tZXNzYWdlKTsKICAgICAgICAgIH0KICAgICAgICB9CgogICAgICAgIGNvbnN0IG1lc3NhZ2VzID0gWw0KICAgICAgICAgIHsNCiAgICAgICAgICAgIHJvbGU6ICAgICJzeXN0ZW0iLA0KICAgICAgICAgICAgY29udGVudDogIllvdSBhcmUgYSBsb2NhbCBjb2RpbmcgYXNzaXN0YW50LiBVc2UgY29udGV4dCB0byBhbnN3ZXIgYWNjdXJhdGVseS4gQmUgY29uY2lzZS4iDQogICAgICAgICAgICAgICsgKGNmID8gYFxuQ3VycmVudCBmaWxlOiAke2NmfWAgOiAiIikKICAgICAgICAgICAgICArICh3ZWJDb250ZXh0ID8gYFxuXG5XRUIgU0VBUkNIIFJFU1VMVFM6XG4ke3dlYkNvbnRleHR9YCA6ICIiKQ0KICAgICAgICAgIH0sDQogICAgICAgICAgLi4uKHJhZ0NvbnRleHQgPyBbeyByb2xlOiJzeXN0ZW0iLCBjb250ZW50OiJDT05URVhUOlxuXG4iICsgcmFnQ29udGV4dCB9XSA6IFtdKSwNCiAgICAgICAgICB7IHJvbGU6InVzZXIiLCBjb250ZW50OiBxIH0NCiAgICAgICAgXTsNCg0KICAgICAgICBwb3N0KHsgdHlwZToic3RhdHVzIiwgdGV4dDoiZ2VuZXJhdGluZy4uLiIgfSk7DQoNCiAgICAgICAgYXdhaXQgc3RyZWFtT2xsYW1hKG1lc3NhZ2VzLCBjaHVuayA9PiB7DQogICAgICAgICAgcG9zdCh7IHR5cGU6InN0cmVhbV9jaHVuayIsIHRleHQ6Y2h1bmsgfSk7DQogICAgICAgIH0pLmNhdGNoKGVyciA9PiB7DQogICAgICAgICAgcG9zdCh7IHR5cGU6ImVycm9yIiwgdGV4dDogIk9sbGFtYSBlcnJvcjogIiArIGVyci5tZXNzYWdlICsgIi4gSXMgJ29sbGFtYSBzZXJ2ZScgcnVubmluZz8iIH0pOw0KICAgICAgICAgIHJldHVybjsNCiAgICAgICAgfSk7DQoNCiAgICAgICAgYmFkZ2VzLnB1c2goIk1vZGVsOiAiICsgbW9kZWwoKSk7DQogICAgICAgIHBvc3QoeyB0eXBlOiJzdHJlYW1fZW5kIiwgYmFkZ2VzIH0pOw0KICAgICAgfSk7DQogICAgfQ0KICB9Ow0KDQogIGNvbnRleHQuc3Vic2NyaXB0aW9ucy5wdXNoKA0KICAgIHZzY29kZS53aW5kb3cucmVnaXN0ZXJXZWJ2aWV3Vmlld1Byb3ZpZGVyKCJjb2duaXRpdmVSYWcuc2lkZWJhciIsIHByb3ZpZGVyLCB7IHdlYnZpZXdPcHRpb25zOiB7IHJldGFpbkNvbnRleHRXaGVuSGlkZGVuOiB0cnVlIH0gfSkNCiAgKTsNCn0NCg0KLy8g4pSA4pSA4pSAIGFjdGl2YXRlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgA0KZnVuY3Rpb24gYWN0aXZhdGUoY29udGV4dCkgew0KDQogIC8vIDEuIFJlZ2lzdGVyIGFzIGEgVlMgQ29kZSBjaGF0IHBhcnRpY2lwYW50IChAcmFnIGluIHRoZSBjaGF0IHBhbmVsKQ0KICBpZiAodnNjb2RlLmNoYXQgJiYgdnNjb2RlLmNoYXQuY3JlYXRlQ2hhdFBhcnRpY2lwYW50KSB7DQogICAgY29uc3QgcGFydGljaXBhbnQgPSB2c2NvZGUuY2hhdC5jcmVhdGVDaGF0UGFydGljaXBhbnQoImNvZ25pdGl2ZVJhZy5jaGF0IiwgaGFuZGxlQ2hhdFJlcXVlc3QpOw0KICAgIHBhcnRpY2lwYW50Lmljb25QYXRoID0gdnNjb2RlLlVyaS5qb2luUGF0aChjb250ZXh0LmV4dGVuc2lvblVyaSwgIm1lZGlhIiwgImljb24ucG5nIik7DQogICAgY29udGV4dC5zdWJzY3JpcHRpb25zLnB1c2gocGFydGljaXBhbnQpOw0KICB9DQoNCiAgLy8gMi4gUmVnaXN0ZXIgc2lkZWJhcg0KICByZWdpc3RlclNpZGViYXIoY29udGV4dCk7DQoNCiAgLy8gMy4gQ29tbWFuZHMNCiAgY29udGV4dC5zdWJzY3JpcHRpb25zLnB1c2goDQogICAgdnNjb2RlLmNvbW1hbmRzLnJlZ2lzdGVyQ29tbWFuZCgiY29nbml0aXZlUmFnLm9wZW5DaGF0IiwgKCkgPT4gew0KICAgICAgdnNjb2RlLmNvbW1hbmRzLmV4ZWN1dGVDb21tYW5kKCJ3b3JrYmVuY2guYWN0aW9uLmNoYXQub3BlbiIsIHsgcXVlcnk6ICJAcmFnICIgfSk7DQogICAgfSkNCiAgKTsNCg0KICBjb250ZXh0LnN1YnNjcmlwdGlvbnMucHVzaCgNCiAgICB2c2NvZGUuY29tbWFuZHMucmVnaXN0ZXJDb21tYW5kKCJjb2duaXRpdmVSYWcucmVwb1Rhc2siLCBhc3luYyAoKSA9PiB7DQogICAgICBjb25zdCB3cyAgID0gdnNjb2RlLndvcmtzcGFjZS53b3Jrc3BhY2VGb2xkZXJzPy5bMF0/LnVyaS5mc1BhdGg7DQogICAgICBjb25zdCBlZGl0b3IgPSB2c2NvZGUud2luZG93LmFjdGl2ZVRleHRFZGl0b3I7DQogICAgICBpZiAoIXdzKSByZXR1cm4gdnNjb2RlLndpbmRvdy5zaG93RXJyb3JNZXNzYWdlKCJPcGVuIGEgd29ya3NwYWNlIGZpcnN0LiIpOw0KICAgICAgY29uc3QgdGFzayA9IGF3YWl0IHZzY29kZS53aW5kb3cuc2hvd0lucHV0Qm94KHsgcHJvbXB0OiAiRGVzY3JpYmUgdGhlIHJlcG8gdGFzayIgfSk7DQogICAgICBpZiAoIXRhc2spIHJldHVybjsNCiAgICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IHJlcG9UYXNrKHdzLCB0YXNrLCBlZGl0b3IgPyB2c2NvZGUud29ya3NwYWNlLmFzUmVsYXRpdmVQYXRoKGVkaXRvci5kb2N1bWVudC51cmkpIDogbnVsbCk7DQogICAgICBjb25zdCBwYW5lbCA9IHZzY29kZS53aW5kb3cuY3JlYXRlV2Vidmlld1BhbmVsKCJyZXBvVGFzayIsICJSZXBvIFRhc2siLCB2c2NvZGUuVmlld0NvbHVtbi5Ud28sIHt9KTsNCiAgICAgIGxldCBodG1sID0gIjxoMj5QbGFuPC9oMj48dWw+IjsNCiAgICAgIChyZXN1bHQucGxhbnx8W10pLmZvckVhY2gocyA9PiB7IGh0bWwgKz0gYDxsaT4ke3MuZGVzY3JpcHRpb259IOKGkiA8Y29kZT4keyhzLmZpbGVzX2FmZmVjdGVkfHxbXSkuam9pbigiLCAiKX08L2NvZGU+PC9saT5gOyB9KTsNCiAgICAgIGh0bWwgKz0gYDwvdWw+PGgyPkVkaXRzICgkeyhyZXN1bHQuZWRpdHN8fFtdKS5sZW5ndGh9KTwvaDI+YDsNCiAgICAgIChyZXN1bHQuZWRpdHN8fFtdKS5mb3JFYWNoKGVkID0+IHsgaHRtbCArPSBgPGRldGFpbHM+PHN1bW1hcnk+JHtlZC5maWxlfSDigJQgJHtlZC5kZXNjcmlwdGlvbn08L3N1bW1hcnk+PHByZT4ke2VkLnRleHR9PC9wcmU+PC9kZXRhaWxzPmA7IH0pOw0KICAgICAgcGFuZWwud2Vidmlldy5odG1sID0gaHRtbDsNCiAgICAgIGlmICgocmVzdWx0LmVkaXRzfHxbXSkubGVuZ3RoID4gMCkgew0KICAgICAgICBjb25zdCBwaWNrID0gYXdhaXQgdnNjb2RlLndpbmRvdy5zaG93UXVpY2tQaWNrKFsiQXBwbHkgYWxsIGVkaXRzIiwiUHJldmlldyBvbmx5Il0pOw0KICAgICAgICBpZiAocGljayA9PT0gIkFwcGx5IGFsbCBlZGl0cyIpIHsgYXdhaXQgYXBwbHlFZGl0cyhyZXN1bHQuZWRpdHMsIHdzKTsgfQ0KICAgICAgfQ0KICAgIH0pDQogICk7DQoNCiAgY29udGV4dC5zdWJzY3JpcHRpb25zLnB1c2goDQogICAgdnNjb2RlLmNvbW1hbmRzLnJlZ2lzdGVyQ29tbWFuZCgiY29nbml0aXZlUmFnLmluZ2VzdERvY3MiLCAoKSA9PiB7DQogICAgICBjb25zdCB3cyA9IHZzY29kZS53b3Jrc3BhY2Uud29ya3NwYWNlRm9sZGVycz8uWzBdPy51cmkuZnNQYXRoIHx8ICIiOw0KICAgICAgY29uc3QgdCAgPSB2c2NvZGUud2luZG93LmNyZWF0ZVRlcm1pbmFsKCJSQUcgSW5nZXN0Iik7DQogICAgICB0LnNlbmRUZXh0KGBjZCAiJHt3c30iICYmIHB5dGhvbiBpbmdlc3QucHlgKTsNCiAgICAgIHQuc2hvdygpOw0KICAgIH0pDQogICk7DQoNCiAgdnNjb2RlLndpbmRvdy5zaG93SW5mb3JtYXRpb25NZXNzYWdlKA0KICAgIGBDb2duaXRpdmUgUkFHIGFjdGl2ZSDigJQgbW9kZWw6ICR7bW9kZWwoKX0uIFR5cGUgQHJhZyBpbiBjaGF0IG9yIHVzZSB0aGUgc2lkZWJhci5gDQogICk7DQp9DQoNCmZ1bmN0aW9uIGRlYWN0aXZhdGUoKSB7fQ0KbW9kdWxlLmV4cG9ydHMgPSB7IGFjdGl2YXRlLCBkZWFjdGl2YXRlIH07"
[System.IO.File]::WriteAllBytes("$EXT\extension.js",[System.Convert]::FromBase64String($jsB64))
OK "extension.js (session persistence + real web search)"

$pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAHsAAABfCAYAAADI+rhfAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAKVSURBVHhe7dHZbeNQEERR7UpSWyja01IiWkLRgAO8DxdtzNjuJovkvUB9s/nO6E217vf7e7VavUejUb+mPzrkeotcpj88xHqPXKY/PqQq5PV6XX+Uvk4fYAgNDrlMH6LPDRa5TB+kjz0ej2Ejl+nD9CmQZfpAfQjkL6YP1eVA/sf0wbpYhbzZbOo/xz5OH65LgfzN6QN2IZB/OH1I557PJ8i/mT6oYyAHTR/WKZCDpw/sEMhJ04duswp5u93Wj2Qx0wdvI5Abmj58k4Hc8BSgiV6vF8htTCEyA7nlKUhGIJtMYSID2WwKFFGFvNvt6h9j7U6hIrrdbvUPsfanUBGBbTqFighs0ylURGCbTqEiAtt0ChUR2KZTqIjANp1CRQS26RQqIrBNp1ARgW06hYoIbNMpVERgm06hIgLbdAoVEdimU6iIwDadQkUEtukUKiKwTadQEYFtOoWKCGzTKVREYPttuVyC3fctFov39Xr96wJ2T1chXy6XDy5g92yfIZfA7snm8/mXyCWwO74K+Xw+K8Gngd3RzWaz/0Yugd2x/QS5BHZHViGfTid96m8Ftvmm0+mvkUtgmy4SuQS22Srk4/GoTxoS2CabTCZpyCWwW14TyCWwW1qFfDgc9OlSA7vhjcfjxpFLYDe0NpFLYCevQt7v9/pErQR24lyQS2AnzA25BHbCXEu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzlMvA9izlMrA9S7kMbM9SLgPbs5TLwPYs5TKwPUu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzlMvA9izlMrA9S7kMbM9SLgPbs5TLwPYs5TKwPUu5DGzPUi4D27OUy8D2LOUysD1LuQxsz1IuA9uzPzg11VRMzj52AAAAAElFTkSuQmCC"
[System.IO.File]::WriteAllBytes("$EXT\media\icon.png",[System.Convert]::FromBase64String($pngB64))
OK "media/icon.png (123x95 original PNG)"

$pkgB64 = "ew0KICAibmFtZSI6ICJjb2duaXRpdmUtcmFnLXYxNiIsDQogICJkaXNwbGF5TmFtZSI6ICJDb2duaXRpdmUgUkFHIHYxNiIsDQogICJkZXNjcmlwdGlvbiI6ICJMb2NhbCBRd2VuMyArIE9sbGFtYSArIEh5YnJpZCBSQUcgKyBSZXBvIEdyYXBoIGNvZGluZyBhc3Npc3RhbnQgd2l0aCBzaWRlYmFyIGFuZCBAcmFnIGNoYXQiLA0KICAidmVyc2lvbiI6ICIxLjYuMCIsDQogICJwdWJsaXNoZXIiOiAieW91cm5hbWUiLA0KICAiaWNvbiI6ICJtZWRpYS9pY29uLnBuZyIsDQoNCiAgImVuZ2luZXMiOiB7DQogICAgInZzY29kZSI6ICJeMS44NS4wIg0KICB9LA0KDQogICJjYXRlZ29yaWVzIjogWw0KICAgICJBSSIsDQogICAgIkNoYXQiLA0KICAgICJQcm9ncmFtbWluZyBMYW5ndWFnZXMiDQogIF0sDQoNCiAgImtleXdvcmRzIjogWw0KICAgICJyYWciLA0KICAgICJvbGxhbWEiLA0KICAgICJxd2VuIiwNCiAgICAibG9jYWwgYWkiLA0KICAgICJjb3BpbG90IiwNCiAgICAicmVwbyBncmFwaCIsDQogICAgImFnZW50IiwNCiAgICAibGxtIg0KICBdLA0KDQogICJhY3RpdmF0aW9uRXZlbnRzIjogWw0KICAgICJvblN0YXJ0dXBGaW5pc2hlZCIsDQogICAgIm9uVmlldzpjb2duaXRpdmVSYWcuc2lkZWJhciIsDQogICAgIm9uQ29tbWFuZDpjb2duaXRpdmVSYWcub3BlbkNoYXQiLA0KICAgICJvbkNvbW1hbmQ6Y29nbml0aXZlUmFnLnJlcG9UYXNrIiwNCiAgICAib25Db21tYW5kOmNvZ25pdGl2ZVJhZy5pbmdlc3REb2NzIiwNCiAgICAib25DaGF0UGFydGljaXBhbnQ6Y29nbml0aXZlUmFnLmNoYXQiDQogIF0sDQoNCiAgIm1haW4iOiAiLi9leHRlbnNpb24uanMiLA0KDQogICJjb250cmlidXRlcyI6IHsNCg0KICAgICJjb25maWd1cmF0aW9uIjogew0KICAgICAgInRpdGxlIjogIkNvZ25pdGl2ZSBSQUciLA0KICAgICAgInByb3BlcnRpZXMiOiB7DQogICAgICAgICJjb2duaXRpdmVSYWcub2xsYW1hVXJsIjogew0KICAgICAgICAgICJ0eXBlIjogInN0cmluZyIsDQogICAgICAgICAgImRlZmF1bHQiOiAiaHR0cDovL2xvY2FsaG9zdDoxMTQzNCIsDQogICAgICAgICAgImRlc2NyaXB0aW9uIjogIkJhc2UgVVJMIGZvciBPbGxhbWEgQVBJIg0KICAgICAgICB9LA0KICAgICAgICAiY29nbml0aXZlUmFnLnJhZ0FwaVVybCI6IHsNCiAgICAgICAgICAidHlwZSI6ICJzdHJpbmciLA0KICAgICAgICAgICJkZWZhdWx0IjogImh0dHA6Ly9sb2NhbGhvc3Q6ODc2NSIsDQogICAgICAgICAgImRlc2NyaXB0aW9uIjogIkJhc2UgVVJMIGZvciBSQUcgYmFja2VuZCBBUEkiDQogICAgICAgIH0sDQogICAgICAgICJjb2duaXRpdmVSYWcubW9kZWwiOiB7DQogICAgICAgICAgInR5cGUiOiAic3RyaW5nIiwNCiAgICAgICAgICAiZGVmYXVsdCI6ICJxd2VuMy42OmxhdGVzdCIsDQogICAgICAgICAgImRlc2NyaXB0aW9uIjogIk9sbGFtYSBtb2RlbCB0byB1c2UiDQogICAgICAgIH0NCiAgICAgIH0NCiAgICB9LA0KDQogICAgImNoYXRQYXJ0aWNpcGFudHMiOiBbDQogICAgICB7DQogICAgICAgICJpZCI6ICJjb2duaXRpdmVSYWcuY2hhdCIsDQogICAgICAgICJuYW1lIjogInJhZyIsDQogICAgICAgICJmdWxsTmFtZSI6ICJDb2duaXRpdmUgUkFHIiwNCiAgICAgICAgImRlc2NyaXB0aW9uIjogIkxvY2FsIFJBRyArIE9sbGFtYSBjb2RpbmcgYXNzaXN0YW50IiwNCiAgICAgICAgImlzU3RpY2t5IjogZmFsc2UNCiAgICAgIH0NCiAgICBdLA0KDQogICAgInZpZXdzQ29udGFpbmVycyI6IHsNCiAgICAgICJhY3Rpdml0eWJhciI6IFsNCiAgICAgICAgew0KICAgICAgICAgICJpZCI6ICJjb2duaXRpdmVSYWciLA0KICAgICAgICAgICJ0aXRsZSI6ICJDb2duaXRpdmUgUkFHIiwNCiAgICAgICAgICAiaWNvbiI6ICJtZWRpYS9pY29uLnBuZyINCiAgICAgICAgfQ0KICAgICAgXQ0KICAgIH0sDQoNCiAgICAidmlld3MiOiB7DQogICAgICAiY29nbml0aXZlUmFnIjogWw0KICAgICAgICB7DQogICAgICAgICAgInR5cGUiOiAid2VidmlldyIsDQogICAgICAgICAgImlkIjogImNvZ25pdGl2ZVJhZy5zaWRlYmFyIiwNCiAgICAgICAgICAibmFtZSI6ICJDb2duaXRpdmUgUkFHIiwNCiAgICAgICAgICAidmlzaWJpbGl0eSI6ICJ2aXNpYmxlIg0KICAgICAgICB9DQogICAgICBdDQogICAgfSwNCg0KICAgICJjb21tYW5kcyI6IFsNCiAgICAgIHsNCiAgICAgICAgImNvbW1hbmQiOiAiY29nbml0aXZlUmFnLm9wZW5DaGF0IiwNCiAgICAgICAgInRpdGxlIjogIkNvZ25pdGl2ZSBSQUc6IE9wZW4gQ2hhdCAoQHJhZykiLA0KICAgICAgICAiY2F0ZWdvcnkiOiAiQ29nbml0aXZlIFJBRyINCiAgICAgIH0sDQogICAgICB7DQogICAgICAgICJjb21tYW5kIjogImNvZ25pdGl2ZVJhZy5yZXBvVGFzayIsDQogICAgICAgICJ0aXRsZSI6ICJDb2duaXRpdmUgUkFHOiBSdW4gUmVwbyBUYXNrIiwNCiAgICAgICAgImNhdGVnb3J5IjogIkNvZ25pdGl2ZSBSQUciDQogICAgICB9LA0KICAgICAgew0KICAgICAgICAiY29tbWFuZCI6ICJjb2duaXRpdmVSYWcuaW5nZXN0RG9jcyIsDQogICAgICAgICJ0aXRsZSI6ICJDb2duaXRpdmUgUkFHOiBSZS1pbmdlc3QgRG9jdW1lbnRzIiwNCiAgICAgICAgImNhdGVnb3J5IjogIkNvZ25pdGl2ZSBSQUciDQogICAgICB9DQogICAgXSwNCg0KICAgICJrZXliaW5kaW5ncyI6IFsNCiAgICAgIHsNCiAgICAgICAgImNvbW1hbmQiOiAiY29nbml0aXZlUmFnLm9wZW5DaGF0IiwNCiAgICAgICAgImtleSI6ICJjdHJsK2FsdCtxIiwNCiAgICAgICAgIndoZW4iOiAiZWRpdG9yVGV4dEZvY3VzIg0KICAgICAgfSwNCiAgICAgIHsNCiAgICAgICAgImNvbW1hbmQiOiAiY29nbml0aXZlUmFnLnJlcG9UYXNrIiwNCiAgICAgICAgImtleSI6ICJjdHJsK2FsdCtyIiwNCiAgICAgICAgIndoZW4iOiAiZWRpdG9yVGV4dEZvY3VzIg0KICAgICAgfQ0KICAgIF0NCiAgfSwNCg0KICAic2NyaXB0cyI6IHsNCiAgICAicGFja2FnZSI6ICJucHggQHZzY29kZS92c2NlIHBhY2thZ2UgLS1uby1kZXBlbmRlbmNpZXMiLA0KICAgICJpbnN0YWxsLWxvY2FsIjogIm5wbSBpbnN0YWxsICYmIG5wbSBydW4gcGFja2FnZSAmJiBjb2RlIC0taW5zdGFsbC1leHRlbnNpb24gY29nbml0aXZlLXJhZy12MTYtMS42LjAudnNpeCINCiAgfSwNCg0KICAiZGV2RGVwZW5kZW5jaWVzIjogew0KICAgICJAdnNjb2RlL3ZzY2UiOiAiXjIuMjIuMCINCiAgfSwNCg0KICAiZGVwZW5kZW5jaWVzIjoge30NCn0="
[System.IO.File]::WriteAllBytes("$EXT\package.json",[System.Convert]::FromBase64String($pkgB64))
OK "package.json (original)"

# ----------------------------------------------------------------
# STEP 12 - BUILD VSIX + INSTALL
# ----------------------------------------------------------------
Step "Building VSIX"
$vsixPath = "$ROOT\cognitive-rag-v16-1.6.0.vsix"
if (Get-Command npm -ErrorAction SilentlyContinue) {
    Push-Location $EXT
    try {
        npm install --save-dev "@vscode/vsce" --silent 2>&1 | Out-Null
        npx "@vscode/vsce" package --no-dependencies --out $vsixPath 2>&1 | Out-Null
        if (Test-Path $vsixPath) { OK "VSIX built" } else { Warn "VSIX build failed - folder install used" }
    } catch { Warn "VSIX skipped: $_" }
    Pop-Location
} else { Warn "npm not found - skipping VSIX" }

Step "Installing extension"
$dest = $env:USERPROFILE + "\.vscode\extensions\cognitive-rag-v16"
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item $EXT -Destination $dest -Recurse
OK "Installed: $dest"
if ((Test-Path $vsixPath) -and (Get-Command code -ErrorAction SilentlyContinue)) {
    code --install-extension $vsixPath --force
    OK "VSIX installed via code CLI"
}

# ----------------------------------------------------------------
# STEP 13 - SAMPLE DOC + LAUNCHERS
# ----------------------------------------------------------------
Step "Sample doc + launchers"
Set-Content "$ROOT\docs\overview.md" -Encoding UTF8 -Value @'
# Cognitive RAG v16
Local AI. Ollama + Qwen3.6. No cloud.
POST /query  POST /retrieve  POST /repo_task  GET /health
'@

$startLines = @(
    "Set-Location `"$ROOT`"",
    "Write-Host `"Model: $MODEL`" -ForegroundColor Cyan",
    "Start-Process ollama -ArgumentList `"serve`" -WindowStyle Hidden -ErrorAction SilentlyContinue",
    "Start-Sleep 3",
    "Write-Host `"API: http://127.0.0.1:$PORT`" -ForegroundColor Cyan",
    "& `"$PY`" -m uvicorn server.api:app --host 127.0.0.1 --port $PORT --reload"
)
$startLines -join "`n" | Set-Content "$ROOT\start_server.ps1" -Encoding UTF8
$ingestLines = @("Set-Location `"$ROOT`"","& `"$PY`" ingest.py")
$ingestLines -join "`n" | Set-Content "$ROOT\ingest_docs.ps1" -Encoding UTF8
OK "start_server.ps1 + ingest_docs.ps1"

# ----------------------------------------------------------------
# DONE
# ----------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Cognitive RAG v16 - COMPLETE" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Model  : $MODEL" -ForegroundColor Cyan
Write-Host " Root   : $ROOT"
Write-Host " API    : http://127.0.0.1:$PORT"
Write-Host ""
Write-Host " NEXT:" -ForegroundColor Yellow
Write-Host "  1. cd `"$ROOT`""
Write-Host "  2. .\start_server.ps1"
Write-Host "  3. VS Code: Ctrl+Shift+P -> Developer: Reload Window"
Write-Host "  4. Click the hexagon icon in the Activity Bar"
Write-Host "  5. (optional) .\ingest_docs.ps1"
Write-Host ""
Write-Host " Fixes in this version:" -ForegroundColor DarkCyan
Write-Host "  Web search button: real DuckDuckGo API (no key)"
Write-Host "  Session history: persists when you switch panels"
Write-Host "  ollama pull: no unicode crash"
Write-Host "  Model: prefers qwen3.6 over qwen3"
Write-Host ""