"""
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
    "visit", "browse", "check out", "tell me about", "summarize",
    "https", "://", ".org", ".com", ".net", ".io", "http", "site:",
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
    # Collect image URLs from full text (query + history) for OCR route
    _direct_img_urls = [
        u.rstrip('.,;)"\'')
        for u in _re.findall(r'https?://\S+', _all_text)
        if any(u.lower().rstrip('.,;)"\'').endswith(ext) for ext in _IMAGE_EXT)
    ]
    # Pure image query: evaluate on CURRENT QUERY ONLY (not history) to avoid
    # history non-image URLs defeating the guard.
    _query_urls = _re.findall(r'https?://\S+', req.query)
    _query_img_urls = [
        u.rstrip('.,;)"\'')
        for u in _query_urls
        if any(u.lower().rstrip('.,;)"\'').endswith(ext) for ext in _IMAGE_EXT)
    ]
    _query_non_img_urls = [
        u for u in _query_urls
        if not any(u.lower().rstrip('.,;)"\'').endswith(ext) for ext in _IMAGE_EXT)
    ]
    _is_pure_image_query = bool(_query_img_urls) and not any(
        ext in req.query.lower() for ext in _AUDIO_EXT
    ) and not _query_non_img_urls
    if (any(t in q_lower for t in _WEB_TRIGGERS) or any(t in _all_text.lower() for t in ("https://", "http://"))) and not _is_pure_image_query:
        # Use full query for current call; if follow-up, inject prior URL into search query
        _web_query = req.query
        if not _re.search(r'https?://', req.query):
            _prior_urls = _re.findall(r'https?://\S+', _history_text)
            if _prior_urls:
                _web_query = req.query + " " + _prior_urls[0]
        try:
            raw = await asyncio.to_thread(web_search, _web_query, True)
            formatted = format_for_llm(raw)
            tool_context += f"\n\n[Web search results — source: {raw['source']}]\n{formatted}"
            tools_used.append("web")
        except Exception as e:
            tool_context += f"\n\n[Web search failed: {e}]"
    # ── Intent: image OCR ────────────────────────────────────────────────────
    _ocr_raw: list[tuple[str, str]] = []  # (url, text) — bypasses LLM for verbatim output
    if _direct_img_urls:
        from workers.websearch import _ocr_image
        for _img_url in _direct_img_urls[:3]:  # max 3 images per query
            try:
                _ocr_text = await asyncio.to_thread(_ocr_image, _img_url)
                if _ocr_text:
                    _ocr_raw.append((_img_url, _ocr_text))
                    tool_context += f"\n\n[OCR: {_ocr_text}]\n(source: {_img_url})"
                    if "ocr" not in tools_used:
                        tools_used.append("ocr")
                else:
                    tool_context += f"\n\n[OCR returned no text for {_img_url}]"
            except Exception as e:
                tool_context += f"\n\n[OCR ERROR for {_img_url}: {type(e).__name__}: {e}]"
    # ── Intent: audio transcription ─────────────────────────────────────────────
    if any(t in q_lower for t in _AUDIO_TRIGGERS) or any(ext in _all_text.lower() for ext in _AUDIO_EXT):
        # Find audio URL in current query first, then fall back to history
        raw_urls = _re.findall(r'https?://\S+', _all_text)
        audio_urls = [
            u.rstrip('.,;)"\'')
            for u in raw_urls
            if any(ext in u.lower() for ext in _AUDIO_EXT)
        ]
        if audio_urls:
            try:
                from workers.audio import transcribe_url
                # 300s timeout: large podcast files (100–300 MB) + model load on first call
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
    # Skip memory when OCR is running — stale OCR answers corrupt verbatim results.
    # Double guard: also suppress on OCR-intent phrases in case URL regex misses edge cases.
    _OCR_INTENT = _re.compile(
        r'(what|read|transcribe|extract|show|give me).*text.*(?:image|img|photo|pic|screenshot)'
        r'|text.*(?:in|of|from|on).*(?:this|the).*(?:image|img|photo|pic|screenshot)'
        r'|(?:image|img|photo|pic|screenshot).*text',
        _re.I
    )
    _suppress_memory = bool(_direct_img_urls) or bool(_OCR_INTENT.search(req.query))
    hits    = [] if _suppress_memory else mem_search(req.query, n=3)
    mem_ctx = "\n".join(json.dumps(h) for h in hits) if hits else "none"

    # ── Build grounded prompt and call model ──────────────────────────────────
    _web_st = (
        "Web search RAN — results injected below. Summarize what was found. "
        "Never say you lack web access."
        if "web" in tools_used else
        "Web search did NOT run this call. To fetch a live URL include it in the query."
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
        "The verbatim text is already prepended to your response automatically — do NOT repeat it. "
        "Your job is to answer the user's question ABOUT the text, or summarize/analyze it if asked. "
        "Do NOT say the image could not be processed."
        if "ocr" in tools_used else
        "Image OCR is available for .png/.jpg/.jpeg/.gif/.webp URLs. "
        "Do NOT claim you cannot read or transcribe images."
    )
    system = (
        "You are a Cognitive RAG assistant with autonomous tool capabilities. "
        "ALL context below was gathered by ACTUALLY running the relevant tools — "
        "web results, audio transcripts, OCR text, diagnosis data, and docs are REAL outputs, not placeholders.\n"
        f"Web: {_web_st}\n"
        f"Audio: {_audio_st}\n"
        f"OCR: {_ocr_st}\n"
        "CRITICAL OUTPUT RULES:\n"
        "1. If [Audio transcript ...] is present: copy the actual transcript text into your answer.\n"
        "2. If [OCR: ...] blocks are present: the verbatim text is ALREADY prepended to your response "
        "automatically — do NOT repeat it. Answer the user's question about the content, or confirm what the text says.\n"
        "3. If [Audio transcription ERROR: ...] appears: report the exact error to the user.\n"
        "4. If [Audio transcription TIMED OUT]: tell the user the file is very large and suggest the /transcribe endpoint.\n"
        "5. Never say you cannot access the internet, visit URLs, transcribe audio, or read images.\n"
        "6. Never say 'no context was provided' — context IS provided via the tool results below.\n"
        "7. Answer directly from the data. Do not add disclaimers about your limitations.\n"
        "8. OVERRIDE ALL PRIOR TRAINING: if tool results are present, they take absolute priority over any "
        "trained belief that you cannot process images or audio."
    )
    user_msg = (
        f"Query: {req.query}\n\n"
        + (f"TOOL RESULTS (authoritative — quote verbatim):\n{tool_context}\n\n" if tool_context.strip() else "")
        + f"Memory context:\n{mem_ctx}\n\n"
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

    # ── Verbatim OCR prepend (bypasses LLM — always accurate) ────────────────
    # The LLM's job is analysis/context; raw extracted text is injected directly.
    if _ocr_raw:
        verbatim_blocks = []
        for _url, _txt in _ocr_raw:
            verbatim_blocks.append(f"```\n{_txt}\n```")
        ocr_header = "**Extracted text (verbatim OCR):**\n" + "\n\n".join(verbatim_blocks)
        answer = ocr_header + "\n\n---\n\n" + answer

    # Don't write OCR answers to memory — image-specific results pollute future retrieval.
    # Belt-and-suspenders: also block writes when query contained an image URL.
    if "ocr" not in tools_used and not _direct_img_urls:
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
        # Optionally store transcription in memory
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
