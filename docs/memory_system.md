# Cognitive RAG v17 — Memory System

## Dual Storage Architecture
Every cognitive event is stored in two places simultaneously:

1. **JSONL event log** at `memory/cognition.jsonl` — append-only, human-readable, source of truth
2. **ChromaDB vector store** at `memory/chroma_mem/` — semantic search index

Both are kept in sync by `embedding_maintenance()` which runs in the background loop.

## Event Types
| event | Triggered by | Contents |
|-------|-------------|----------|
| `cycle_start` | cognition_cycle() | query, cycle id |
| `cycle_end` | cognition_cycle() | query, reasoning, reflection, memory_hits |
| `ext` | /memory/store | id, text, meta (from VS Code extension) |
| `loop_diagnosis` | background_loop slot 3 | corrupt_lines, error_entries, chroma_count, jsonl_count, issues |
| `loop_cleanup` | background_loop slot 7 | removed, kept, chroma_removed |
| `loop_health_check` | background_loop slot 8 | report (code metrics), commentary (AI sentence) |
| `loop_consolidate` | background_loop slot 9 | consolidation stats, embedding stats |
| `loop_skip` | background_loop | reason: "ollama busy" |
| `loop_error` | background_loop | task, error, traceback |

## brain.py Functions

### write(entry: dict)
Appends to JSONL and upserts into ChromaDB. Unloads nomic-embed-text after each write to free VRAM.

### search(query: str, n: int = 5) → list
Semantic search via ChromaDB first, keyword fallback if unavailable. Returns list of entry dicts.

### recent(n: int = 20) → list
Returns n most recent entries sorted by timestamp descending.

### memory_consolidation(max_per_query: int = 3) → dict
Deduplicates `cycle_end` entries: keeps only the 3 most recent per unique query string. Prevents unbounded growth from repeated self-probes. Rewrites JSONL in-place.

### self_diagnosis() → dict
Scans JSONL for:
- Corrupt (non-JSON) lines
- Entries containing `[ollama error:` strings (model was unstable)
- ChromaDB vs JSONL count drift > 50 entries
Returns structured report dict.

### embedding_maintenance() → dict
Gets all IDs from ChromaDB, computes expected MD5 UIDs for all JSONL entries, re-embeds any missing ones. Closes the sync gap caused by ChromaDB errors or VRAM unloads.

### cleanup_old_data(max_entries: int = 500) → dict
Trims JSONL to the most recent 500 entries. Deletes corresponding ChromaDB documents for the removed entries. Calls `_unload_embed_model()` when done.

## Embedding Model
Uses `nomic-embed-text:latest` via Ollama at `http://localhost:11434/api/embeddings`.
Always unloaded via `_unload_embed_model()` immediately after each ChromaDB operation (keeps `keep_alive: 0s`) to prevent VRAM conflict with `cograg-gpu`.

## ChromaDB Collection
Collection name: `cogmem`
Stored in: `memory/chroma_mem/`
Each document contains: the text (reasoning, query, or stored text), truncated to 2000 chars.
Metadata fields: `t` (Unix timestamp), `event` (event type string).
