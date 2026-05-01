"""
FIX-7:  MODEL_GPU defined as a proper module-level name so api.py can import it.
FIX-14: Single Ollama semaphore prevents background loop from starving user queries.
         _chat timeout raised to 300s for large MoE model on partial-GPU.
         Background loop interval raised to 300s (5 min) so it rarely interferes.
FIX-18: background_loop now rotates through AI cognition AND 4 maintenance tasks
         prescribed by the local AI itself via /repo_task self-analysis:
         memory_consolidation, self_diagnosis, code_health_check, embedding_maintenance,
         cleanup_old_data. The model comments on its own health reports.
"""
import asyncio, json, os, traceback, urllib.request
from memory.brain import write, search

MODEL_GPU = "cograg-gpu"
MODEL_RAW = "qwen3:latest"
MODEL     = MODEL_GPU   # alias used internally

STATE = {"cycle": 0, "running": True}

# Limit Ollama to one concurrent request; user queries acquire with priority=0 (immediate),
# background probes skip if the semaphore is already held.
_ollama_sem = asyncio.Semaphore(1)

def _chat(messages, temp=0.1, model=None, timeout=180):
    m    = model or MODEL
    body = json.dumps({
        "model": m, "messages": messages, "stream": False, "think": False,
        "keep_alive": "30m",
        "options": {"temperature": temp, "num_ctx": 4096}
    }).encode()
    req = urllib.request.Request(
        "http://localhost:11434/api/chat", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()).get("message", {}).get("content", "")
    except Exception as e:
        return f"[ollama error: {e}]"

async def cognition_cycle(query: str) -> dict:
    STATE["cycle"] += 1
    cid  = STATE["cycle"]
    write({"event": "cycle_start", "cycle": cid, "query": query})
    hits = search(query, n=3)
    mem  = "\n".join(json.dumps(h) for h in hits) if hits else "none"
    # Single semaphore acquisition for both reasoning + reflection —
    # avoids releasing between calls which could block a waiting user query
    async with _ollama_sem:
        reasoning = await asyncio.to_thread(_chat, [
            {"role": "system", "content": "You are a concise reasoning engine."},
            {"role": "user",   "content": f"Query: {query}\nMemory:\n{mem}\nAnswer concisely."}
        ], 0.1, None, 60)
        reflection = await asyncio.to_thread(_chat, [
            {"role": "user", "content": f"One sentence to remember: Q={query} A={reasoning[:200]}"}
        ], 0.2, None, 60)
    write({"event": "cycle_end", "cycle": cid, "query": query,
           "reasoning": reasoning, "reflection": reflection})
    return {"cycle": cid, "query": query, "reasoning": reasoning,
            "reflection": reflection, "memory_hits": len(hits)}

async def background_loop():
    """Autonomous maintenance loop — 10-slot rotation, one task every 5 minutes.
    Prescribed by the local AI's own self-analysis via /repo_task:
      Slots 0,1,2,4,5,6 → cognition probes (AI reasoning about its own state)
      Slot 3            → self_diagnosis  (JSONL integrity + ChromaDB sync check)
      Slot 7            → cleanup_old_data (trim to 500 entries)
      Slot 8            → code_health_check + AI summary of findings
      Slot 9            → memory_consolidation + embedding_maintenance
    Full rotation = 50 minutes. Skips any slot if Ollama is busy serving user.
    """
    from memory.brain import (memory_consolidation, self_diagnosis,
                               embedding_maintenance, cleanup_old_data)
    from graph.repo  import code_health_check

    WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    PROBES = [
        "What patterns emerged from recent queries and what do they suggest?",
        "What knowledge gaps exist in the memory store that should be filled?",
        "What changed recently across the codebase and what does it imply?",
    ]
    # 10-slot schedule: (task_name, probe_index_or_None)
    SCHEDULE = [
        ("cognition", 0), ("cognition", 1), ("cognition", 2),
        ("diagnosis",    None),
        ("cognition", 0), ("cognition", 1), ("cognition", 2),
        ("cleanup",      None),
        ("health_check", None),
        ("consolidate",  None),
    ]

    tick = 0
    while STATE["running"]:
        await asyncio.sleep(300)
        if not STATE["running"]:
            break
        if _ollama_sem.locked():
            write({"event": "loop_skip", "reason": "ollama busy", "tick": tick})
            tick += 1
            continue

        task, arg = SCHEDULE[tick % len(SCHEDULE)]
        try:
            if task == "cognition":
                await cognition_cycle(PROBES[arg])

            elif task == "diagnosis":
                report = await asyncio.to_thread(self_diagnosis)
                write({"event": "loop_diagnosis", **report})

            elif task == "cleanup":
                result = await asyncio.to_thread(cleanup_old_data, 500)
                write({"event": "loop_cleanup", **result})

            elif task == "health_check":
                report = await asyncio.to_thread(code_health_check, WORKSPACE)
                # Only ask model if sem is free — don't block for this commentary
                if not _ollama_sem.locked():
                    async with _ollama_sem:
                        commentary = await asyncio.to_thread(_chat, [{
                            "role": "user",
                            "content": (
                                f"Code health report for this project: {json.dumps(report)}. "
                                "In one sentence, what is the most important thing to address?"
                            )
                        }], 0.1, None, 60)
                else:
                    commentary = "(skipped — Ollama busy)"
                write({"event": "loop_health_check", "report": report,
                       "commentary": commentary})

            elif task == "consolidate":
                r1 = await asyncio.to_thread(memory_consolidation, 3)
                r2 = await asyncio.to_thread(embedding_maintenance)
                write({"event": "loop_consolidate", "consolidation": r1, "embedding": r2})

        except Exception as e:
            write({"event": "loop_error", "task": task,
                   "error": str(e), "trace": traceback.format_exc()})
        tick += 1

async def run(query: str) -> dict:
    return await cognition_cycle(query)

def stop():
    STATE["running"] = False
