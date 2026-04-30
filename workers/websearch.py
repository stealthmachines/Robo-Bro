"""
Web search: tries SearXNG (self-hosted) -> Brave API -> DuckDuckGo instant -> Bing scraper.
Also fetches full page text from result URLs, preserves image URLs for OCR, and
transcribes image content using the local moondream vision model.
"""
import os, json, urllib.request, urllib.parse, html, re

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8888")
BRAVE_KEY   = os.environ.get("BRAVE_API_KEY", "")
DDG_URL     = "https://api.duckduckgo.com/"

_BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# Compiled pattern to find [IMG: url] markers injected by _strip_html
_IMG_MARKER_RE = re.compile(r'\[IMG:\s*(https?://[^\]]+)\]')

# Cached easyocr Reader (loaded once on first use)
_easyocr_reader = None

def _get_easyocr_reader():
    global _easyocr_reader
    if _easyocr_reader is None:
        import easyocr as _easyocr
        # Force CPU — GPU is occupied by Ollama (RTX 2060 shared)
        _easyocr_reader = _easyocr.Reader(["en"], gpu=False, verbose=False)
    return _easyocr_reader

def _strip_html(raw: str) -> str:
    raw = re.sub(r"<script[^>]*>.*?</script>", "", raw, flags=re.DOTALL | re.IGNORECASE)
    raw = re.sub(r"<style[^>]*>.*?</style>",   "", raw, flags=re.DOTALL | re.IGNORECASE)
    # Preserve image src URLs as readable markers before stripping tags
    raw = re.sub(
        r'<img[^>]+src=["\']([^"\']+)["\'][^>]*/?>',
        r'[IMG: \1] ',
        raw,
        flags=re.IGNORECASE,
    )
    raw = re.sub(r"<[^>]+>", " ", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"\s{3,}", "\n", raw)
    # 150K chars — a single Discourse post can be 150K; threads can exceed 1M.
    # format_for_llm then selects how much to pass to the LLM based on context budget.
    return raw[:150000].strip()

def _fetch_url(url: str, timeout=10) -> str:
    """Fetch a URL using requests (browser UA, better TLS). Falls back to Google/Bing cache."""
    candidates = [url]
    domain_only = re.sub(r"https?://", "", url).rstrip("/")
    candidates.append(f"https://webcache.googleusercontent.com/search?q=cache:{url}")
    candidates.append(
        f"https://cc.bingj.com/cache.aspx?q={urllib.parse.quote(domain_only)}"
        f"&url={urllib.parse.quote(url)}"
    )

    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

    for attempt_url in candidates:
        # Try requests first (better TLS negotiation / redirect handling)
        try:
            import requests as _req
            sess = _req.Session()
            sess.headers.update({
                "User-Agent":      _BROWSER_UA,
                "Accept":          "text/html,application/xhtml+xml,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
                "Accept-Encoding": "identity",
            })
            r = sess.get(attempt_url, timeout=(5, timeout), verify=False,
                         allow_redirects=True, stream=False)
            if r.status_code == 200 and len(r.content) > 200:
                text = _strip_html(r.text)
                if len(text) > 100:
                    return text
        except Exception:
            pass
        # urllib fallback
        try:
            req = urllib.request.Request(attempt_url, headers={"User-Agent": _BROWSER_UA})
            opener = urllib.request.build_opener(
                urllib.request.HTTPRedirectHandler(),
                urllib.request.HTTPSHandler(context=ctx),
            )
            with opener.open(req, timeout=timeout) as r:
                ct = r.headers.get("Content-Type", "")
                if "text" in ct or "html" in ct:
                    raw = r.read(2097152).decode("utf-8", errors="ignore")  # 2 MB raw
                    text = _strip_html(raw)
                    if len(text) > 100:
                        return text
        except Exception:
            pass
    return ""

def _searxng(query: str, n=5) -> list:
    try:
        url = (f"{SEARXNG_URL}/search?q={urllib.parse.quote(query)}"
               f"&format=json&engines=google,bing&language=en")
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read())
        return [{"title": i.get("title", ""), "url": i.get("url", ""),
                 "snippet": i.get("content", "")} for i in data.get("results", [])[:n]]
    except Exception:
        return []

def _brave(query: str, n=5) -> list:
    if not BRAVE_KEY:
        return []
    try:
        url = f"https://api.search.brave.com/res/v1/web/search?q={urllib.parse.quote(query)}&count={n}"
        req = urllib.request.Request(url, headers={
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "X-Subscription-Token": BRAVE_KEY
        })
        with urllib.request.urlopen(req, timeout=6) as r:
            data    = json.loads(r.read())
            results = data.get("web", {}).get("results", [])
        return [{"title": i.get("title", ""), "url": i.get("url", ""),
                 "snippet": i.get("description", "")} for i in results[:n]]
    except Exception:
        return []

def _ddg(query: str) -> list:
    try:
        url = (f"{DDG_URL}?q={urllib.parse.quote(query)}"
               f"&format=json&no_redirect=1&no_html=1&skip_disambig=1")
        req = urllib.request.Request(url, headers={"User-Agent": "cognitive-rag/1.7"})
        with urllib.request.urlopen(req, timeout=6) as r:
            j = json.loads(r.read())
        parts = []
        if j.get("AbstractText"):
            parts.append({"title": j.get("Heading", ""), "url": j.get("AbstractURL", ""),
                          "snippet": j["AbstractText"]})
        if j.get("Answer"):
            parts.append({"title": "Answer", "url": "", "snippet": j["Answer"]})
        for t in (j.get("RelatedTopics") or [])[:4]:
            if t.get("Text"):
                parts.append({"title": t.get("FirstURL", ""), "url": t.get("FirstURL", ""),
                              "snippet": t["Text"]})
        return parts
    except Exception:
        return []

_DOMAIN_RE = re.compile(
    r"https?://[^\s\"'>]+|(?<!\w)([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?"
    r"\.(?:org|com|net|io|gov|edu|co|ai|dev|app|info|biz)(?:/[^\s\"'>]*)?)",
    re.IGNORECASE
)

def _extract_urls(text: str) -> list:
    """Pull any bare domains or full URLs out of a query string."""
    out = []
    for m in _DOMAIN_RE.finditer(text):
        url = m.group(0)
        if not url.startswith("http"):
            url = "https://" + url
        out.append(url)
    return out

def _bing_scrape(query: str, n=5) -> list:
    """Scrape Bing search results page — fallback when APIs return nothing."""
    try:
        import requests as _req
        url = f"https://www.bing.com/search?q={urllib.parse.quote(query)}&count={n}"
        r = _req.get(url, headers={
            "User-Agent":      _BROWSER_UA,
            "Accept":          "text/html,*/*",
            "Accept-Encoding": "identity",
            "Accept-Language": "en-US,en;q=0.9",
        }, timeout=8, verify=False, allow_redirects=True)
        if r.status_code != 200:
            return []
        results = []
        title_blocks   = re.findall(r'<h2[^>]*><a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>', r.text)
        snippet_blocks = re.findall(r'<p class="b_lineclamp\d[^"]*">(.+?)</p>', r.text, re.DOTALL)
        for i, (url_found, title) in enumerate(title_blocks[:n]):
            if url_found.startswith("http") and "bing.com" not in url_found:
                snippet = html.unescape(
                    re.sub(r"<[^>]+>", " ", snippet_blocks[i])
                ).strip() if i < len(snippet_blocks) else ""
                results.append({
                    "title":   html.unescape(title),
                    "url":     url_found,
                    "snippet": snippet,
                })
        return results
    except Exception:
        return []

_OCR_DESCRIPTION_PREFIXES = (
    "the image shows", "the image contains", "the image depicts",
    "this image shows", "this image contains", "this image depicts",
    "the picture shows", "the photo shows", "i can see",
    "the text in this image", "the image is",
)

def _moondream_generate(b64img: str, prompt: str) -> str:
    import ollama as _ol
    resp = _ol.generate(
        model="moondream:latest",
        prompt=prompt,
        images=[b64img],
        options={"temperature": 0.0, "num_predict": 1024},
    )
    if hasattr(resp, "response"):
        return (resp.response or "").strip()
    return resp.get("response", "").strip()

def _ocr_image(img_url: str) -> str:
    """Download an image and extract text using easyocr (primary) or moondream (fallback)."""
    try:
        import requests as _req, base64
        r = _req.get(img_url, timeout=10, verify=False,
                     headers={"User-Agent": _BROWSER_UA}, allow_redirects=True)
        if r.status_code != 200 or len(r.content) < 500:
            return ""
        ct = r.headers.get("Content-Type", "")
        if not any(t in ct for t in ("image/", "jpeg", "png", "gif", "webp")):
            return ""

        # --- Primary: easyocr (real character-level OCR) ---
        try:
            import numpy as _np
            from PIL import Image as _PILImage, ImageEnhance as _IE, ImageFilter as _IF
            import io as _io

            img = _PILImage.open(_io.BytesIO(r.content)).convert("RGB")

            # Upscale small images — easyocr CRAFT needs ≥ ~800px wide to resolve
            # math superscripts and subscripts reliably
            w, h = img.size
            if w < 1200:
                scale = max(2, 1200 // w)
                img = img.resize((w * scale, h * scale), _PILImage.LANCZOS)

            # Sharpen + boost contrast — helps with low-quality forum screenshots
            img = img.filter(_IF.SHARPEN)
            img = _IE.Contrast(img).enhance(1.5)

            arr = _np.array(img)
            # detail=1 → returns (bbox, text, confidence) tuples so we can sort
            results = _get_easyocr_reader().readtext(
                arr,
                detail=1,
                paragraph=False,        # paragraph=True merges aggressively and loses math structure
                width_ths=0.7,          # allow wider horizontal merging of character clusters
                height_ths=0.5,
            )

            if results:
                # Sort by top-left y then x (reading order: top→bottom, left→right)
                results.sort(key=lambda r: (r[0][0][1], r[0][0][0]))

                # Group into lines: boxes whose y-centres are within 20px of each other
                # are on the same line; join with space, separate lines with newline
                lines = []
                cur_line = []
                cur_y = None
                for bbox, word, _conf in results:
                    y_centre = (bbox[0][1] + bbox[2][1]) / 2
                    if cur_y is None or abs(y_centre - cur_y) < 20:
                        cur_line.append(word)
                        cur_y = y_centre if cur_y is None else (cur_y + y_centre) / 2
                    else:
                        lines.append(" ".join(cur_line))
                        cur_line = [word]
                        cur_y = y_centre
                if cur_line:
                    lines.append(" ".join(cur_line))

                text = "\n".join(lines).strip()
                if text:
                    return text
        except Exception:
            pass

        # --- Fallback: moondream vision model ---
        b64 = base64.b64encode(r.content).decode()
        text = _moondream_generate(
            b64,
            "Read and transcribe all text visible in this image.",
        )
        return text
    except Exception:
        return ""

def _ocr_page_images(text: str, max_images: int = 6) -> str:
    """Replace [IMG: url] markers in page text with moondream OCR transcriptions."""
    markers = _IMG_MARKER_RE.findall(text)
    if not markers:
        return text
    for url in markers[:max_images]:
        ocr = _ocr_image(url)
        placeholder = f"[IMG: {url}]"
        if ocr:
            text = text.replace(placeholder, f"[OCR: {ocr}]", 1)
        else:
            text = text.replace(placeholder, "", 1)
    # Remove any remaining unprocessed markers beyond max_images
    text = _IMG_MARKER_RE.sub("", text)
    return re.sub(r"\s{3,}", "\n", text).strip()

def search(query: str, fetch_pages=True, n=5) -> dict:
    results = _searxng(query, n)
    source  = "searxng" if results else None
    if not results:
        results = _brave(query, n)
        source  = "brave" if results else None
    if not results:
        results = _ddg(query)
        source  = "ddg" if results else None
    if not results:
        results = _bing_scrape(query, n)
        source  = "bing" if results else None
    pages = {}
    if fetch_pages and results:
        for r in results[:2]:
            u = r.get("url", "")
            if u and u.startswith("http"):
                text = _fetch_url(u)
                if text:
                    pages[u] = _ocr_page_images(text)
    # Fallback: if no results at all, try fetching any URL/domain in the query directly
    if not results:
        for url in _extract_urls(query):
            text = _fetch_url(url)
            if text:
                text = _ocr_page_images(text)
                results.append({"title": url, "url": url, "snippet": text[:1200]})
                pages[url] = text
                source = "direct_fetch"
                break
    return {"results": results, "source": source or "none", "pages": pages}

def format_for_llm(result: dict) -> str:
    pages     = result.get("pages", {})
    num_pages = max(1, sum(1 for r in result["results"] if r.get("url", "") in pages))
    # Budget: 100K chars total across all pages (≈25K tokens), shared equally.
    # Minimum 10K per page so short pages are still informative.
    per_page  = max(10000, 100000 // num_pages)
    lines = []
    for i, r in enumerate(result["results"]):
        lines.append(f"[{i+1}] {r['title']}\n{r['snippet']}")
        url = r.get("url", "")
        if url in pages:
            lines.append(f"    Full text excerpt:\n{pages[url][:per_page]}")
    return "\n\n".join(lines)
