# Cognitive RAG v17 — Architecture

## Stack Overview
- **FastAPI backend** on port 8765 (`server/api.py`)
- **Ollama** on port 11434 running `cograg-gpu` model (qwen3:latest 8B by default)
- **ChromaDB** for vector storage: `chroma_db/` (documents), `memory/chroma_mem/` (cognition)
- **VS Code Extension** (`vscode-extension/extension.js`) — sidebar panel + @rag chat participant
- **Embeddings**: `nomic-embed-text:latest` via Ollama, always unloaded after use to free VRAM

## Module Layout
```
core/engine.py      — inference engine, cognition_cycle(), background_loop()
server/api.py       — FastAPI app, all 11 HTTP endpoints
memory/brain.py     — ChromaDB memory ops, JSONL event log, maintenance functions
graph/repo.py       — tree-sitter AST repo index, code_health_check()
workers/retriever.py — hybrid BM25 + ChromaDB retriever
workers/websearch.py — SearXNG → Brave → DuckDuckGo search cascade
```

## Request Flow — /query
1. Extension POSTs `{"query": "..."}` to `/query`
2. `api.py` calls `mem_search()` for memory context, `retrieve()` for doc chunks
3. Builds prompt with memory + chunks, calls Ollama `cograg-gpu`
4. Returns `{"answer": "...", "sources": [...]}`

## Request Flow — /repo_task
1. Extension sends task + workspace root + current file
2. `api.py` builds repo graph via `graph/repo.py`, reads file context
3. Calls Ollama with structured JSON prompt (plan/edits/summary schema)
4. Returns `{"plan": [...], "edits": [...], "summary": "..."}`

## GPU Configuration
- Model: `cograg-gpu` defined in `Modelfile.gpu`
- Default: `FROM qwen3:latest` (8B, 5.2 GB VRAM)
- `num_ctx: 4096`, `num_thread: 8`
- VRAM: 6.1 GB used of 12 GB (RTX 2060)
- To restore 30B: reboot → change FROM to `qwen3.6:latest` → `ollama create cograg-gpu -f Modelfile.gpu`

## Background Maintenance Loop (50-minute rotation)
| Slot | Task |
|------|------|
| 0,1,2 | Cognition probes (AI reasons about its own state) |
| 3 | `self_diagnosis()` — JSONL integrity + ChromaDB drift check |
| 4,5,6 | Cognition probes |
| 7 | `cleanup_old_data(500)` — trim JSONL + ChromaDB |
| 8 | `code_health_check()` + AI commentary on findings |
| 9 | `memory_consolidation(3)` + `embedding_maintenance()` |

Results queryable at `GET /maintenance`.
