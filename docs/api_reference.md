# Cognitive RAG v17 — API Reference

## Endpoints

### GET /health
Returns stack status and current cognition cycle counter.
```json
{"status": "v17 online", "model": "cograg-gpu", "cycle": 42}
```

### GET /gpu_status
Returns GPU name, VRAM usage, and active model.
```json
{"name": "NVIDIA GeForce RTX 2060", "mem_used_mb": "6281", "mem_total_mb": "12288", "gpu_util_pct": "12", "model": "cograg-gpu"}
```

### POST /query
Main chat endpoint. Performs RAG over documents and memory.
```json
// Request
{"query": "How does the memory system work?"}

// Response
{"answer": "...", "sources": ["doc1.md", "..."], "memory_hits": 3}
```

### POST /retrieve
Pure document retrieval — no LLM call. Returns raw chunks from ChromaDB + BM25.
```json
// Request
{"query": "embedding maintenance", "n": 5}

// Response
{"chunks": ["chunk text...", "..."], "sources": ["architecture.md"]}
```

### POST /web_search
Cascading web search: SearXNG → Brave API → DuckDuckGo.
```json
// Request
{"query": "qwen3 model architecture"}

// Response
{"results": [{"title": "...", "url": "...", "snippet": "..."}], "source": "ddg"}
```

### POST /fim
Fill-in-the-middle code completion.
```json
// Request
{"prefix": "def calculate(x):\n    ", "suffix": "\n    return result", "language": "python"}

// Response
{"completion": "result = x * 2"}
```

### POST /repo_task
AI-powered code task: reads repo graph, plans and generates edits.
```json
// Request
{"task": "Add input validation to /query endpoint", "workspace_root": "C:/path/to/repo", "current_file": "server/api.py"}

// Response
{"plan": [{"description": "..."}], "edits": [{"file": "server/api.py", "start_line": 45, "content": "..."}], "summary": "..."}
```

### POST /memory/store
Store a document in the cognitive memory (ChromaDB + JSONL).
```json
// Request
{"id": "note-1", "text": "Important finding about X", "meta": {"source": "user"}}

// Response
{"ok": true}
```

### POST /memory/query
Semantic search over cognitive memory.
```json
// Request
{"query": "embedding maintenance findings"}

// Response
{"results": {"documents": [["relevant memory text..."]]}}
```

### GET /memory/recent
Returns the 20 most recent memory entries (cognition cycles, maintenance events, ext stores).

### GET /maintenance
Returns last 30 autonomous maintenance events. Events include:
- `loop_diagnosis` — JSONL/ChromaDB integrity report
- `loop_health_check` — code complexity report + AI commentary
- `loop_cleanup` — data trim results
- `loop_consolidate` — deduplication + re-embedding results
- `loop_skip` — skipped because Ollama was busy
- `loop_error` — exception during maintenance task
