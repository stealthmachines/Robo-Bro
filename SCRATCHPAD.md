# Cognitive RAG — Shared Scratchpad

> A live working surface for both of us. Edit freely.
> Add notes with `## [date] [who]` headers.
> I (Copilot) will append here whenever something needs tracking between sessions.

---

## [2026-04-29] Copilot — Session State

### Stack currently running
| Service | URL | Status |
|---------|-----|--------|
| Ollama | http://localhost:11434 | ✅ running (qwen3:latest loaded, 6.1 GB VRAM) |
| FastAPI | http://localhost:8765 | ✅ running |
| VS Code extension | sidebar | ⚠️ needs `F1 → Developer: Reload Window` to activate FIX-16 |

### Active model
- **cograg-gpu** ← `qwen3:latest` (Qwen3-8B, Q4_K_M, 5.2 GB)
- To upgrade to 30B: **reboot first**, then:
  ```
  (edit Modelfile.gpu line 1: FROM qwen3.6:latest)
  ollama create cograg-gpu -f Modelfile.gpu
  ```

### Immediate open items
- [ ] `F1 → Developer: Reload Window` (extension.js changes aren't live yet)
- [ ] `docker-compose up` in `searxng-compose.yml` to enable real web search
- [ ] Run `python ingest.py` on your docs to populate ChromaDB (retrieve returns 0 now)
- [ ] Start Ollama with `OLLAMA_FLASH_ATTENTION=0` env var for stability (add to `start_server.ps1`)

### What the bot does autonomously (right now)
`background_loop()` in `core/engine.py` runs every **5 minutes** while the FastAPI server is up.
It asks itself one of three questions, writes the answer to `memory/cognition.jsonl`, and
embeds it in ChromaDB. This happens with no user prompt. It skips if you're actively querying.
That is the extent of autonomous operation — I (Copilot) cannot act between your messages.

---

## [2026-04-29] Copilot — Research Notes from Upstream Repos

### flash-moe-HDGL
- K=8 active MoE experts → 8 background probe types (current loop has 3)
- Circular reward accumulator (S¹ phase angle) → better loop_skip threshold than locked semaphore
- `+38%` throughput from "trust the OS" GPU split (validates wu-wei Modelfile.gpu change)

### Analog-Prime
- right-brain-left-brain.py = retriever.py (left) + engine.py (right)
- Nullweaver Ω BEAST MODE frontier kernels — future fused inference path

### conscious (128-bit floor)
- `lk_advance()` epoch ratchet → forward secrecy for brain.py writes
- sigma-trit gate {-1,0,+1} → apply to reflection step in cognition_cycle
- chat_win.exe + bot.exe = direct ancestor of this VS Code extension + api.py

### Hopfield-Superconducting A+
- `FluidRAM` class: vortex-addressed memory (∮v·dl keys, not cosine similarity)
- `Kuramoto R` metric: |mean(e^iθ_k)| → confidence score for /query responses
- `NavierStokesReasoner`: fluid token flow — longer-term inference architecture

---

## Notes for me (user)

*(add anything here)*

---
