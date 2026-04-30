import requests, sys, json

# Route through the extension bridge (port 8766) so the full extension
# pipeline runs: health-check → /query → refusal detection → restart+retry
BASE    = "http://localhost:8766"
ENDPOINT = "/agent-query"

def q(label, query, history=None):
    if history is None:
        history = []
    print(f"\n{'='*60}")
    print(f"TEST: {label}")
    print(f"{'='*60}")
    try:
        r = requests.post(f"{BASE}{ENDPOINT}", json={"query": query, "history": history}, timeout=300)
        d = r.json()
        tools   = d.get("tools_used", [])
        hits    = d.get("memory_hits", -1)
        ans     = d.get("answer", "")
        via     = d.get("_via", "direct")
        retried = d.get("_retried", False)
        restarted = d.get("_auto_restarted", False)
        print(f"via           : {via}")
        print(f"retried       : {retried}  |  auto_restarted: {restarted}")
        print(f"tools_used    : {tools}")
        print(f"memory_hits   : {hits}")
        print(f"starts_verbatim: {ans.startswith('**Extracted text')}")
        print(f"--- answer (first 1200) ---")
        print(ans[:1200])
        return d
    except Exception as e:
        print(f"ERROR: {e}")
        return {}

# ---------- OCR IMAGE 1 ----------
r1 = q(
    "IMG-1 entropy text Jan-2025",
    "what is the text of this image? https://forum.zchg.org/uploads/default/original/2X/6/6d3b62d36d63c2cf62d3683dc4f47989af5c63ed.png"
)

# ---------- OCR IMAGE 2 ----------
r2 = q(
    "IMG-2 Omega/Coulombs latest post",
    "read the equations in this image https://forum.zchg.org/uploads/default/original/2X/6/6b65c71cec4b082238b256c052feee6a7c4e1d54.png"
)

# ---------- OCR IMAGE 3 ----------
r3 = q(
    "IMG-3 Mar-2025 refined expression",
    "extract the text from this image https://forum.zchg.org/uploads/default/original/2X/a/a3c5d610f30e4ae8269233dad3f6a5fff6ed5f0f.png"
)

# ---------- MULTI-TURN FOLLOW-UP on IMG-1 ----------
if r1.get("answer"):
    excerpt = r1["answer"][:400].replace('"', "'")
    orig_q  = "what is the text of this image? https://forum.zchg.org/uploads/default/original/2X/6/6d3b62d36d63c2cf62d3683dc4f47989af5c63ed.png"
    hist = [
        {"role": "user",      "content": orig_q},
        {"role": "assistant", "content": r1["answer"][:600]},
    ]
    q(
        "MULTI-TURN: ask about equations seen in IMG-1",
        "What were the main equations or formulas you found in that image?",
        history=hist
    )

# ---------- MP3 AUDIO TEST ----------
# Using a smaller ~4MB file for speed
q(
    "AUDIO: Mysteries of Gravity #2",
    "transcribe this audio file https://zchg.org/hott/late%20episodes/1159%20-%209-Jul-97%20-%20Mysteries%20of%20Gravity%20%232.mp3"
)
