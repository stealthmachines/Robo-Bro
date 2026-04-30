"""
Cognitive RAG v17 - Full function test suite (20 tests).
Run with: python -m pytest tests/ -v --tb=short
Integration tests require the API server running on port 8765.
"""
import pytest, json, time, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

BASE = "http://127.0.0.1:8765"

try:
    import httpx
    CLIENT    = httpx.Client(base_url=BASE, timeout=60)
    SERVER_UP = CLIENT.get("/health").status_code == 200
except Exception:
    SERVER_UP = False

skip_no_server = pytest.mark.skipif(not SERVER_UP, reason="API server not running on :8765")

# â”€â”€ Unit: memory â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestMemoryBrain:
    def test_write_and_load(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, load
        write({"event": "test", "text": "hello world"})
        data = load()
        assert len(data) == 1
        assert data[0]["text"] == "hello world"

    def test_search_keyword_fallback(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, search
        write({"event": "t1", "text": "python async await"})
        write({"event": "t2", "text": "javascript promises"})
        results = search("python async", n=5)
        assert len(results) >= 1

    def test_recent_order(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        from memory.brain import write, recent
        write({"event": "a", "text": "first"})
        time.sleep(0.02)
        write({"event": "b", "text": "second"})
        r = recent(5)
        assert r[0]["text"] == "second"

# â”€â”€ Unit: repo graph â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestRepoGraph:
    def test_build_and_summary(self, tmp_path):
        (tmp_path / "main.py").write_text("def hello():\n    pass\nclass World:\n    pass\n")
        (tmp_path / "util.js").write_text("function greet() { return 'hi'; }\nconst x = 1;\n")
        from graph.repo import build, summary, REPO_INDEX
        result = build(str(tmp_path))
        assert result["files"] == 2
        s = summary()
        assert "main.py" in s or "util.js" in s

    def test_symbol_extraction_python(self, tmp_path):
        f = tmp_path / "code.py"
        f.write_text("def foo(): pass\ndef bar(): pass\nclass Baz: pass\n")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        rel = "code.py"
        if rel in REPO_INDEX:
            syms = REPO_INDEX[rel]["symbols"]
            assert len(syms) >= 2

    def test_ignores_node_modules(self, tmp_path):
        nm = tmp_path / "node_modules" / "lib"
        nm.mkdir(parents=True)
        (nm / "index.js").write_text("function hidden() {}")
        (tmp_path / "app.py").write_text("def visible(): pass")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        assert not any("node_modules" in k for k in REPO_INDEX.keys())

    def test_complexity_count(self, tmp_path):
        f = tmp_path / "c.py"
        f.write_text("if True:\n    for x in y:\n        while z:\n            pass\n")
        from graph.repo import build, REPO_INDEX
        build(str(tmp_path))
        assert REPO_INDEX.get("c.py", {}).get("complexity", 0) >= 3

# â”€â”€ Unit: web search helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestWebSearch:
    def test_ddg_returns_list(self):
        from workers.websearch import _ddg
        r = _ddg("Python programming language")
        assert isinstance(r, list)

    def test_format_for_llm(self):
        from workers.websearch import format_for_llm
        fake = {"results": [{"title": "T1", "url": "http://x.com", "snippet": "S1"},
                             {"title": "T2", "url": "",             "snippet": "S2"}],
                "pages": {}}
        out = format_for_llm(fake)
        assert "[1]" in out and "[2]" in out

    def test_strip_html(self):
        from workers.websearch import _strip_html
        raw = "<html><body><p>Hello <b>World</b></p><script>bad()</script></body></html>"
        out = _strip_html(raw)
        assert "Hello" in out
        assert "<" not in out
        assert "bad()" not in out

# â”€â”€ Integration: health + GPU â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestAPIHealth:
    @skip_no_server
    def test_health_endpoint(self):
        r = CLIENT.get("/health")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "v17 online"
        assert "model" in body

    @skip_no_server
    def test_gpu_status_shape(self):
        r = CLIENT.get("/gpu_status")
        assert r.status_code == 200
        body = r.json()
        assert "model" in body or "error" in body

# â”€â”€ Integration: core query â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestAPIQuery:
    @skip_no_server
    def test_query_returns_answer(self):
        r = CLIENT.post("/query", json={"query": "What is 2+2?"})
        assert r.status_code == 200
        body = r.json()
        assert "answer" in body
        assert len(body["answer"]) > 0

    @skip_no_server
    def test_retrieve_graceful_empty_db(self):
        r = CLIENT.post("/retrieve", json={"query": "test query"})
        assert r.status_code == 200
        assert "chunks" in r.json()

    @skip_no_server
    def test_web_search_source_field(self):
        r = CLIENT.post("/web_search", json={"query": "Python asyncio tutorial"})
        assert r.status_code == 200
        body = r.json()
        assert body["source"] in ("searxng", "brave", "ddg", "none")
        assert "formatted" in body

# â”€â”€ Integration: FIM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestFIM:
    @skip_no_server
    def test_fim_python(self):
        r = CLIENT.post("/fim", json={
            "prefix": "def add(a, b):\n    return ",
            "suffix": "\n\ndef subtract(a, b):",
            "language": "python",
            "max_tokens": 16
        })
        assert r.status_code == 200
        assert "completion" in r.json()

    @skip_no_server
    def test_fim_javascript(self):
        r = CLIENT.post("/fim", json={
            "prefix": "function greet(name) {\n  return ",
            "suffix": "\n}",
            "language": "javascript",
            "max_tokens": 32
        })
        assert r.status_code == 200

# â”€â”€ Integration: memory â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class TestMemoryAPI:
    @skip_no_server
    def test_store_and_query(self):
        uid = f"test-{int(time.time())}"
        s   = CLIENT.post("/memory/store",
                          json={"id": uid, "text": "cograg test entry unique phrase xyzzy"})
        assert s.status_code == 200
        time.sleep(0.4)
        q    = CLIENT.post("/memory/query", json={"query": "xyzzy unique phrase"})
        assert q.status_code == 200
        docs = q.json().get("results", {}).get("documents", [[]])[0]
        assert isinstance(docs, list)

    @skip_no_server
    def test_recent_entries(self):
        r = CLIENT.get("/memory/recent")
        assert r.status_code == 200
        assert "entries" in r.json()
