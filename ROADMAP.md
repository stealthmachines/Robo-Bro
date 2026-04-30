# Cognitive RAG — Roadmap

> Milestones derived from session history and upstream repo analysis.
> Status: `[x]` done · `[-]` in progress · `[ ]` not started

---

## v17 — Current (Stable)
- [x] FIX-1 through FIX-13: installer, imports, GPU detection, FIM fallback, etc.
- [x] FIX-14: `brain.py` — nomic-embed-text VRAM unload after every ChromaDB op
- [x] FIX-15: `engine.py` — `_ollama_sem` Semaphore(1), 300s timeout, 300s probe interval
- [x] FIX-16: `engine.py` + `api.py` + `extension.js` — `think:false` + `keep_alive:"30m"` everywhere
- [x] FIX-17: `Modelfile.gpu` — wu-wei (no num_gpu, auto-plan), num_ctx 4096
- [x] All 10 endpoints verified working: health, gpu_status, query, retrieve, web_search, fim, repo_task, memory/store, memory/query, memory/recent
- [x] Installer (`versioning/`) synced with all FIX-14 through FIX-17 changes

### Known Constraint
- `cograg-gpu` runs on **qwen3:latest** (Qwen3-8B, 5.2 GB) due to WDDM VRAM fragmentation on Windows preventing `cudaMalloc` for the 30B MoE model.
- **To restore qwen3.6:latest (30B)**: reboot → edit `Modelfile.gpu` line 1 → `ollama create cograg-gpu -f Modelfile.gpu`

---

## v17.1 — Near-term Hardening

- [ ] **lk_advance() epoch ratchet** in `memory/brain.py`
  - Forward secrecy: each write advances a logical epoch; old keys cannot decrypt new events
  - Pattern from `conscious` repo (bot.exe HDGL-28 router)
  - Applicable as optional memory encryption layer

- [ ] **Kuramoto coherence R** as confidence score in API responses
  - From Hopfield-Superconducting A+ (`FluidTransformerKernel`)
  - R = |mean(e^iθ_k)| over attention heads → scalar in [0,1] appended to `/query` response
  - Lets the VS Code extension show a "confidence bar"

- [ ] **SearXNG container** — plug `/web_search` into a real result stream
  - `searxng-compose.yml` already in repo, just needs `docker-compose up`
  - Add `SEARXNG_URL` to `.env` or `start_server.ps1`

- [ ] **Document ingestion** — run `ingest.py` on `/docs` to populate ChromaDB
  - `/retrieve` currently returns 0 chunks because no docs have been ingested
  - Add a `watch` mode: auto-ingest on file save

- [ ] **Streaming `/query` endpoint**
  - Current `/query` waits for full response; add `GET /query/stream` (SSE)
  - Extension already handles streaming (the Ollama direct path)
  - FastAPI backend should proxy the stream so memory/reflection still run

---

## v18 — Multi-Provider (Installer exists in `versioning/`)
- [ ] Universal LLM router: Ollama, LM Studio, OpenAI, Anthropic, Gemini, Groq, Together, Jan
- [ ] `providers.json` — switch models without restarting
- [ ] Embeddings always local (nomic-embed-text) even when chat uses cloud
- [ ] Provider picker in VS Code sidebar + live model name badge
- [ ] 25 total tests (up from 20)

---

## v19+ — Research / Upstream Concepts

### FluidRAM Vortex Memory (from Hopfield-Superconducting A+)
- Replace ChromaDB flat vector store with vortex-addressed memory
- Addresses become circulation integrals (∮v·dl) not cosine similarity
- Implementation target: `memory/brain.py` — drop-in swap for `_get_chroma()`

### Dual-Hemisphere Architecture (from Analog-Prime / right-brain-left-brain.py)
- Left hemisphere: `workers/retriever.py` (structured, symbolic retrieval)
- Right hemisphere: `core/engine.py` (generative, associative reasoning)
- Add a **Corpus Callosum** bridge: structured retrieval result feeds directly into reasoning context in a typed handoff, not just string concatenation

### Docker / VS Code Containerization (from conscious-128-bit-floor)
- Containerize the full stack: FastAPI + Ollama + ChromaDB + nomic-embed-text
- `docker-compose.yml` with GPU passthrough (`runtime: nvidia`)
- VS Code Dev Container config (`.devcontainer/`)
- Eventually: migrate away from bare-metal Ollama entirely

### HDGL Temporal Routing (from flash-moe-HDGL / Analog-Prime)
- `background_loop()` probes are currently round-robin; HDGL routing would make them
  context-sensitive — probe selection based on recent query embeddings
- K=8 active experts ≈ 8 parallel background probe threads (one per expert)
- Circular reward accumulator (S¹ phase angle) replaces scalar threshold in
  loop_skip logic

### σ-trit Gate (from conscious `conscious_fused_engine.cu`)
- Three-state activation: {-1, 0, +1} (suppress / pass / amplify)
- Apply to reflection step in `cognition_cycle` — reflection either amplifies,
  passes, or suppresses the reasoning before writing to memory
