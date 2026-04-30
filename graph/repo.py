"""
Repo graph with Tree-sitter semantic AST parsing.
Falls back to regex if tree-sitter grammar not available.
"""
from pathlib import Path
import re

REPO_INDEX = {}
CODE_EXTS  = {".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".java",
               ".cs", ".cpp", ".c", ".rb", ".vue"}
IGNORE     = {"node_modules", ".venv", "__pycache__", ".git", "dist", "build"}
SYM_RE     = re.compile(
    r"^(?:def |class |function |const |let |var |func |pub fn |fn |async fn |export )([A-Za-z_]\w*)",
    re.MULTILINE)

_ts_parsers = {}

def _get_ts_parser(ext):
    if ext in _ts_parsers:
        return _ts_parsers[ext]
    try:
        import tree_sitter_python as tspy
        import tree_sitter_javascript as tsjs
        from tree_sitter import Language, Parser
        lang_map = {
            ".py":  tspy.language(),
            ".js":  tsjs.language(),
            ".ts":  tsjs.language(),
            ".jsx": tsjs.language(),
            ".tsx": tsjs.language(),
        }
        if ext in lang_map:
            p = Parser(Language(lang_map[ext]))
            _ts_parsers[ext] = p
            return p
    except Exception:
        pass
    _ts_parsers[ext] = None
    return None

def _extract_symbols_ts(content: str, ext: str) -> list:
    parser = _get_ts_parser(ext)
    if parser is None:
        return SYM_RE.findall(content)[:20]
    try:
        tree = parser.parse(bytes(content, "utf-8"))
        syms = []
        def walk(node):
            if node.type in ("function_definition", "class_definition",
                             "function_declaration", "method_definition",
                             "lexical_declaration", "variable_declaration"):
                for child in node.children:
                    if child.type == "identifier":
                        syms.append(child.text.decode("utf-8", errors="ignore"))
                        break
            for child in node.children:
                walk(child)
        walk(tree.root_node)
        return syms[:25]
    except Exception:
        return SYM_RE.findall(content)[:20]

def _complexity(content: str) -> int:
    return len(re.findall(r'\b(if|else|elif|for|while|switch|case|catch|except|and|or)\b', content))

def build(workspace_root):
    REPO_INDEX.clear()
    root = Path(workspace_root)
    for ext in CODE_EXTS:
        for f in root.rglob(f"*{ext}"):
            if any(p in f.parts for p in IGNORE):
                continue
            try:
                rel     = str(f.relative_to(root))
                content = f.read_text(encoding="utf-8", errors="ignore")
                REPO_INDEX[rel] = {
                    "symbols":    _extract_symbols_ts(content, ext),
                    "lines":      content.count("\n"),
                    "complexity": _complexity(content),
                    "size":       len(content),
                }
            except Exception:
                pass
    return {"files": len(REPO_INDEX)}

def summary(max_files=30) -> str:
    out    = []
    ranked = sorted(REPO_INDEX.items(), key=lambda x: x[1].get("complexity", 0), reverse=True)
    for f, d in ranked[:max_files]:
        syms = ", ".join(d["symbols"][:8]) if d["symbols"] else "-"
        cc   = d.get("complexity", 0)
        out.append(f"{f} ({d['lines']} lines, CC={cc}) [{syms}]")
    return "\n".join(out) or "No files indexed."

def get_file_context(workspace_root: str, relative_path: str) -> str:
    try:
        p = Path(workspace_root) / relative_path
        return p.read_text(encoding="utf-8", errors="ignore")[:6000]
    except Exception:
        return ""


def code_health_check(workspace_root: str = None) -> dict:
    """Analyze codebase for complexity hotspots, large files, and symbol-less modules.
    Called autonomously by background_loop; result is stored in memory."""
    import os as _os
    root = workspace_root or _os.getcwd()
    if not REPO_INDEX:
        build(root)
    high_cc = sorted(
        [(f, d["complexity"]) for f, d in REPO_INDEX.items() if d["complexity"] > 15],
        key=lambda x: x[1], reverse=True
    )
    large = sorted(
        [(f, d["lines"]) for f, d in REPO_INDEX.items() if d["lines"] > 200],
        key=lambda x: x[1], reverse=True
    )
    no_syms = [f for f, d in REPO_INDEX.items() if not d["symbols"]]
    total_complexity = sum(d["complexity"] for d in REPO_INDEX.values())
    return {
        "total_files":      len(REPO_INDEX),
        "total_complexity": total_complexity,
        "high_complexity":  [{"file": f, "cc": c} for f, c in high_cc[:5]],
        "largest_files":    [{"file": f, "lines": l} for f, l in large[:5]],
        "no_symbols":       no_syms[:10],
    }
