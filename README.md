# Cognitive RAG v17

A self-maintaining local AI assistant with retrieval-augmented generation, persistent memory, image OCR, audio transcription, and live web search — running entirely on your own hardware via Ollama.

---

## Features

| Capability | Detail |
|---|---|
| **RAG over docs** | Hybrid BM25 + ChromaDB semantic retrieval over your ingested documents |
| **Persistent memory** | Dual JSONL + ChromaDB cognitive memory with background consolidation |
| **Image OCR** | Real character-level OCR via easyocr (primary) + pix2tex LaTeX for formula regions; moondream as last-resort fallback |
| **Audio transcription** | Transcribe audio URLs via faster-whisper (CPU tiny model, chunked via ffmpeg) |
| **Web search** | Cascading search: SearXNG → Brave API → DuckDuckGo with page fetch |
| **Repo intelligence** | tree-sitter AST index, code health checks, FIM completions |
| **VS Code extension** | Sidebar panel + `@rag` chat participant + `Ctrl+Alt+Q` keybinding; auto-starts backend on activation; 60s watchdog with LLM refusal detection + auto-restart |
| **Agent bridge** | HTTP bridge on `:8766` (`POST /agent-query`) lets automation drive the full extension pipeline programmatically |
| **Multi-turn chat** | Full conversation history threading in sidebar and `@rag` participant with deduplication |
| **Background maintenance** | 50-minute rotation loop: self-diagnosis, cleanup, consolidation, health check |

---

## Stack

- **Python 3.11** + FastAPI backend on `:8765`
- **Ollama** on `:11434` — `cograg-gpu` model (qwen3:latest 8B, 32K context)
- **ChromaDB** — vector storage for documents and memory
- **easyocr** — primary OCR engine (CRAFT+CRNN, CPU mode, `gpu=False`)
- **pix2tex 0.1.4** — LaTeX OCR for formula-dense image regions (CPU)
- **moondream:latest** — fallback vision model (used only when easyocr yields nothing)
- **faster-whisper** — CPU audio transcription
- **nomic-embed-text:latest** — embeddings (auto-unloaded after each use to free VRAM)
- **SearXNG** (optional, via Docker) — self-hosted search frontend

Tested on: Windows 11, RTX 2060 12GB, CUDA 11.

---

## Quick Start

### 1. Prerequisites

- [Ollama](https://ollama.com) installed and running
- Python 3.11+
- ffmpeg (for audio chunking): `choco install ffmpeg`
- (Optional) Docker for SearXNG

Pull the required models:
```powershell
ollama pull qwen3:latest
ollama pull nomic-embed-text:latest
ollama pull moondream:latest
```

### 2. Install

Run the patched installer (creates `.venv`, installs dependencies, builds `cograg-gpu` model):
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\cognitive-rag-v17-installer-patched.ps1
```

Or manually:
```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install fastapi uvicorn ollama chromadb rank-bm25 faster-whisper requests beautifulsoup4 tree-sitter easyocr pix2tex
ollama create cograg-gpu -f Modelfile.gpu
```

### 3. Start the server

```powershell
.\start_server.ps1        # watchdog loop with auto-restart
# or directly:
.\.venv\Scripts\python.exe -m uvicorn server.api:app --host 0.0.0.0 --port 8765
```

### 4. Ingest documents

Drop files into `docs/` then:
```powershell
.\ingest_docs.ps1
# or:
.\.venv\Scripts\python.exe ingest.py
```

### 5. Install the VS Code extension

```powershell
code --install-extension cognitive-rag-v17-1.7.0.vsix
```

Or install from `vscode-extension/` via `F1 → Extensions: Install from VSIX`.

The extension:
- **Auto-starts** the backend server on VS Code activation
- **60s watchdog** heartbeat — restarts the server if it goes down
- **LLM refusal detection** — if the model returns "can't access the internet", restarts and retries automatically
- **Multi-turn history** — full conversation threading in sidebar and `@rag` chat participant
- **Agent bridge** on `:8766` for programmatic access through the full extension pipeline

---

## API Reference

### `GET /health`
```json
{"status": "v17 online", "model": "cograg-gpu", "cycle": 42}
```

### `GET /gpu_status`
```json
{"name": "NVIDIA GeForce RTX 2060", "mem_used_mb": "6281", "mem_total_mb": "12288"}
```

### `POST /query`
Main chat endpoint — RAG + memory + tool dispatch (OCR, audio, web search).
```json
// Request
{"query": "transcribe https://example.com/image.png", "history": []}

// Response
{"answer": "...", "sources": [...], "tools_used": ["ocr"]}
```

### `POST /retrieve`
Pure retrieval — no LLM, returns raw chunks.
```json
{"query": "memory system", "n": 5}
```

### `POST /web_search`
```json
{"query": "qwen3 architecture"}
```

### `POST /fim`
Fill-in-the-middle code completion.
```json
{"prefix": "def hello(", "suffix": ":\n    pass", "language": "python"}
```

### `POST /repo_task`
Workspace-aware code task. Returns structured plan + edits.
```json
{"task": "add type hints to all functions", "workspace_root": "C:/project", "current_file": "utils.py"}
```

### `POST /memory/store`
Store a note in persistent memory.
```json
{"text": "User prefers concise answers", "meta": {"source": "preference"}}
```

### `POST /memory/store`
Store a note in persistent memory.
```json
{"text": "User prefers concise answers", "meta": {"source": "preference"}}
```

### `GET /memory/recent`
Returns the 20 most recent memory entries.

---

## Agent Bridge (port 8766)

The VS Code extension exposes a local HTTP bridge that routes requests through the extension's full pipeline (health-check → `/query` → refusal detection → auto-restart+retry):

### `GET http://localhost:8766/agent-health`
```json
{"status": "ok", "extension": "cognitive-rag-v17"}
```

### `POST http://localhost:8766/agent-query`
```json
// Request
{"query": "read the equations in https://example.com/image.png", "history": []}

// Response — same as /query plus extension metadata
{"answer": "...", "tools_used": ["ocr"], "memory_hits": 0, "_via": "extension-bridge"}
```

The `_retried` and `_auto_restarted` flags indicate whether the extension triggered a server restart mid-query.

Use `cognitiveRag.agentSend` VS Code command to inject a query directly into the **visible** sidebar UI (user bubble + streamed response):
```js
vscode.commands.executeCommand("cognitiveRag.agentSend", "your query here");
```

---

## Tool Dispatch (in `/query`)

The backend auto-detects intent and routes to the appropriate tool:

| Trigger | Tool |
|---|---|
| URL ending in `.png/.jpg/.jpeg/.gif/.webp/.bmp` | easyocr (upscaled, contrast-boosted) + pix2tex for formula regions; moondream fallback |
| URL ending in `.mp3/.wav/.m4a/.ogg/.flac/.opus/.webm` | faster-whisper transcription |
| Keywords: `search`, `look up`, `what is`, `latest`, `news`, `https://` (non-image/audio) | Web search |
| Everything else | Hybrid RAG retrieval |

OCR results are prepended **verbatim** before the LLM answer (`**Extracted text (verbatim OCR):**`) — the LLM cannot rephrase or hallucinate them. OCR queries skip memory search and write (no pollution from image content).

---

## Project Structure

```
server/api.py           — FastAPI app, all endpoints, tool dispatch, verbatim OCR prepend, memory suppression
core/engine.py          — Inference engine, cognition_cycle(), background_loop()
memory/brain.py         — ChromaDB + JSONL memory, consolidation, diagnosis
graph/repo.py           — tree-sitter AST repo index, code_health_check()
workers/retriever.py    — Hybrid BM25 + ChromaDB retrieval
workers/websearch.py    — Web search cascade + easyocr primary OCR + pix2tex LaTeX + moondream fallback
workers/websearch.py    — Audio transcription (faster-whisper, chunked via ffmpeg)
vscode-extension/       — VS Code extension (sidebar + @rag participant + agent bridge :8766)
docs/                   — Architecture, API, and memory system docs
versioning/             — Historical installer versions
Modelfile.gpu           — Ollama model definition (qwen3:latest, num_ctx 32768)
ingest.py               — Document ingestion into ChromaDB
start_server.ps1        — Watchdog restart loop
test_live.py            — Live end-to-end test suite (OCR + audio + multi-turn via extension bridge)
```

---

## Memory System

Cognitive memory uses a dual-store approach:

- **`memory/cognition.jsonl`** — append-only human-readable event log (source of truth)
- **`memory/chroma_mem/`** — ChromaDB vector index for semantic search

Events include: `cycle_end` (reasoning traces), `ext` (manually stored notes), `loop_diagnosis`, `loop_health_check`, and more.

Background loop (every 50 minutes) automatically:
- Runs cognition probes (AI reasons about its own state)
- Diagnoses JSONL integrity and ChromaDB drift
- Trims memory to the most recent 500 entries
- Consolidates duplicate cycle entries
- Runs code health checks on the repo itself

---

## GPU Notes

- Default model: `cograg-gpu` = `qwen3:latest` 8B with `num_ctx 32768`
- VRAM: ~6.1 GB used of 12 GB on RTX 2060
- `nomic-embed-text` is unloaded immediately after every embedding call to prevent VRAM conflict
- To switch to a larger model: edit `Modelfile.gpu` → `ollama create cograg-gpu -f Modelfile.gpu`
- `cublas64_12.dll` absent on CUDA 11 — model runs on CUDA 11 via Ollama's bundled runtime

---

## Running Tests

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_all.py -q --tb=short
```

19/19 tests expected to pass.

---

## SearXNG (Optional)

Start a local SearXNG instance for private web search:
```powershell
docker compose -f searxng-compose.yml up -d
```

The backend automatically prefers SearXNG on `http://localhost:8080` over Brave/DDG when available.

---

<img width="1024" height="1536" alt="image" src="https://github.com/user-attachments/assets/b82968a1-373f-4d30-949f-2ac5ee0bb552" />

## License

See [LICENSE](LICENSE).
