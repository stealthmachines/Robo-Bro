"use strict";
const vscode = require("vscode");
const http   = require("http");
const https  = require("https");
const path   = require("path");
const cp     = require("child_process");
const fs     = require("fs");

// â”€â”€ Config â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function cfg(key)      { return vscode.workspace.getConfiguration("cognitiveRag").get(key); }
function ollamaUrl()   { return cfg("ollamaUrl")   || "http://localhost:11434"; }
function ragUrl()      { return cfg("ragApiUrl")   || "http://localhost:8765"; }
function model()       { return cfg("model")       || "cograg-gpu"; }
function inlineDelay() { return cfg("inlineDelay") ?? 350; }

// â”€â”€ HTTP helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function httpPost(baseUrl, endpoint, body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts    = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json",
                  "Content-Length": Buffer.byteLength(payload) }
    };
    const req = lib.request(opts, res => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve({ error: data }); }
      });
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// FIX-12: GPU status uses correct GET method
function httpGet(baseUrl, endpoint) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(baseUrl + endpoint);
    const lib    = parsed.protocol === "https:" ? https : http;
    const opts   = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "GET"
    };
    const req = lib.request(opts, res => {
      let data = "";
      res.on("data", c => data += c);
      res.on("end", () => {
        try { resolve(JSON.parse(data)); } catch { resolve({ error: data }); }
      });
    });
    req.on("error", reject);
    req.end();
  });
}

function httpPostStream(baseUrl, endpoint, body, onChunk) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const parsed  = new URL(baseUrl + endpoint);
    const lib     = parsed.protocol === "https:" ? https : http;
    const opts    = {
      hostname: parsed.hostname,
      port:     parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path:     parsed.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json",
                  "Content-Length": Buffer.byteLength(payload) }
    };
    const req = lib.request(opts, res => {
      let buf = "";
      res.on("data", chunk => {
        buf += chunk.toString();
        const lines = buf.split("\n");
        buf = lines.pop();
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const obj = JSON.parse(line);
            if (obj.message && obj.message.content) {
              const filtered = _filterThink(obj.message.content);
              if (filtered) onChunk(filtered);
            }
            if (obj.response !== undefined) {
              const filtered = _filterThink(obj.response);
              if (filtered) onChunk(filtered);
            }
            if (obj.done) resolve();
          } catch {}
        }
      });
      res.on("end", () => resolve());
    });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// â”€â”€ Utilities â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
async function ragRetrieve(query) {
  try {
    const d = await httpPost(ragUrl(), "/retrieve", { query });
    if (!d.chunks || d.chunks.length === 0) return "";
    return d.chunks.slice(0, 5)
      .map((c, i) => `[${i+1}] ${c.source}\n${c.content}`)
      .join("\n\n---\n\n");
  } catch { return ""; }
}

async function repoTask(workspaceRoot, task, currentFile) {
  try {
    return await httpPost(ragUrl(), "/repo_task", {
      workspace_root: workspaceRoot, task, current_file: currentFile || null
    });
  } catch (e) {
    return { plan: [], edits: [], summary: "RAG server not running: " + e.message };
  }
}

// Strip Qwen3 <think>…</think> blocks from a streaming buffer
let _thinkBuf = "", _inThink = false;
function _resetThinkState() { _thinkBuf = ""; _inThink = false; }
function _filterThink(chunk) {
  let out = "";
  _thinkBuf += chunk;
  while (true) {
    if (_inThink) {
      const end = _thinkBuf.indexOf("</think>");
      if (end === -1) { _thinkBuf = ""; return out; }
      _inThink  = false;
      _thinkBuf = _thinkBuf.slice(end + 8);
    } else {
      const start = _thinkBuf.indexOf("<think>");
      if (start === -1) { out += _thinkBuf; _thinkBuf = ""; return out; }
      out      += _thinkBuf.slice(0, start);
      _inThink  = true;
      _thinkBuf = _thinkBuf.slice(start + 7);
    }
  }
}

async function streamOllama(messages, onChunk) {
  _resetThinkState();
  const body = {
    model: model(), messages, stream: true, think: false, keep_alive: "30m",
    options: { temperature: 0.1, num_ctx: 16384 }
  };
  await httpPostStream(ollamaUrl(), "/api/chat", body, onChunk);
}

async function applyEdits(edits, workspaceRoot) {
  const we = new vscode.WorkspaceEdit();
  for (const ed of edits) {
    const uri   = vscode.Uri.file(path.join(workspaceRoot, ed.file));
    const range = new vscode.Range(
      new vscode.Position(Math.max(0, ed.start_line), 0),
      new vscode.Position(Math.max(0, ed.end_line),   0)
    );
    we.replace(uri, range, ed.text);
  }
  await vscode.workspace.applyEdit(we);
}

// â”€â”€ Inline completion provider (ghost text FIM) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function registerInlineCompletions(context) {
  let debounceTimer = null;
  const provider = {
    provideInlineCompletionItems(document, position, _ctx, token) {
      if (!cfg("inlineEnabled")) return { items: [] };
      return new Promise(resolve => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(async () => {
          if (token.isCancellationRequested) { resolve({ items: [] }); return; }
          const prefixRange = new vscode.Range(
            new vscode.Position(Math.max(0, position.line - 40), 0), position);
          const prefix = document.getText(prefixRange);
          const suffixRange = new vscode.Range(
            position,
            new vscode.Position(
              Math.min(document.lineCount - 1, position.line + 10),
              document.lineAt(Math.min(document.lineCount - 1, position.line + 10)).text.length
            )
          );
          const suffix = document.getText(suffixRange);
          if (prefix.trim().length < 4) { resolve({ items: [] }); return; }
          try {
            const result = await httpPost(ragUrl(), "/fim", {
              prefix, suffix,
              language: document.languageId || "plaintext",
              max_tokens: 96
            });
            const completion = (result.completion || "").trimEnd();
            if (!completion || token.isCancellationRequested) { resolve({ items: [] }); return; }
            const item = new vscode.InlineCompletionItem(completion);
            item.range = new vscode.Range(position, position);
            resolve({ items: [item] });
          } catch {
            resolve({ items: [] });
          }
        }, inlineDelay());
      });
    }
  };
  context.subscriptions.push(
    vscode.languages.registerInlineCompletionItemProvider({ pattern: "**" }, provider)
  );
}

// â”€â”€ Sidebar webview HTML â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function getSidebarHtml(currentModel) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cognitive RAG v17</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--vscode-font-family);font-size:13px;color:var(--vscode-foreground);
     background:var(--vscode-sideBar-background);display:flex;flex-direction:column;height:100vh;overflow:hidden}
.header{padding:8px 12px;border-bottom:1px solid var(--vscode-panel-border);
        display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.model-badge{display:flex;align-items:center;gap:5px;font-size:11px;
             background:var(--vscode-badge-background);color:var(--vscode-badge-foreground);
             padding:2px 8px;border-radius:10px;max-width:60%;overflow:hidden;
             white-space:nowrap;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:#a78bfa;flex-shrink:0}
.history{flex:1;overflow-y:auto;padding:10px 12px;display:flex;flex-direction:column;gap:8px}
.msg{padding:7px 10px;border-radius:6px;font-size:12px;line-height:1.65;
     white-space:pre-wrap;word-break:break-word}
.msg.user{background:var(--vscode-input-background);border:1px solid var(--vscode-input-border)}
.msg.ai{background:var(--vscode-editor-inactiveSelectionBackground)}
.badge-row{display:flex;flex-wrap:wrap;gap:4px;margin-top:5px}
.tbadge{font-size:10px;padding:2px 7px;border-radius:8px;
        border:1px solid var(--vscode-panel-border);color:var(--vscode-descriptionForeground)}
.tools-row{display:flex;flex-wrap:wrap;gap:4px;padding:6px 12px;
           border-top:1px solid var(--vscode-panel-border);flex-shrink:0}
.tchip{font-size:11px;padding:2px 9px;border-radius:10px;cursor:pointer;
       border:1px solid var(--vscode-panel-border);color:var(--vscode-foreground);
       background:var(--vscode-input-background)}
.tchip.on{border-color:#a78bfa;color:#a78bfa;background:rgba(167,139,250,.08)}
.input-area{padding:8px 12px;border-top:1px solid var(--vscode-panel-border);flex-shrink:0}
textarea{width:100%;padding:6px 8px;font-family:inherit;font-size:12px;resize:none;
         background:var(--vscode-input-background);color:var(--vscode-input-foreground);
         border:1px solid var(--vscode-input-border);border-radius:4px;line-height:1.5;
         min-height:52px;max-height:120px}
textarea:focus{outline:1px solid var(--vscode-focusBorder)}
.btn-row{display:flex;gap:6px;margin-top:5px;flex-wrap:wrap}
button{padding:4px 10px;font-size:11px;border-radius:3px;cursor:pointer;
       font-family:inherit;border:1px solid var(--vscode-button-border,transparent)}
.primary{background:var(--vscode-button-background);color:var(--vscode-button-foreground)}
.primary:hover{background:var(--vscode-button-hoverBackground)}
.sec{background:var(--vscode-button-secondaryBackground);color:var(--vscode-button-secondaryForeground)}
.status{font-size:10px;color:var(--vscode-descriptionForeground);margin-left:auto;align-self:center}
.spinner{display:inline-block;width:8px;height:8px;
         border:1.5px solid var(--vscode-descriptionForeground);
         border-top-color:transparent;border-radius:50%;
         animation:spin .6s linear infinite;margin-right:4px}
.gpu-bar{font-size:10px;padding:3px 12px;
         background:var(--vscode-statusBar-background,#1e1e1e);
         color:var(--vscode-statusBar-foreground,#ccc);
         flex-shrink:0;display:flex;gap:8px}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="header">
  <div class="model-badge"><div class="dot"></div>${currentModel}</div>
  <span style="font-size:10px;color:var(--vscode-descriptionForeground)">local Â· GPU</span>
</div>
<div class="history" id="history"></div>
<div class="tools-row" id="tools-row">
  <div class="tchip on" data-tool="rag"  onclick="toggleTool(this)">Hybrid RAG</div>
  <div class="tchip on" data-tool="repo" onclick="toggleTool(this)">Repo graph</div>
  <div class="tchip"    data-tool="web"  onclick="toggleTool(this)">Web search</div>
  <div class="tchip on" data-tool="mem"  onclick="toggleTool(this)">Memory</div>
</div>
<div class="gpu-bar" id="gpu-bar">â¬¡ GPU: checking...</div>
<div class="input-area">
  <textarea id="q"
    placeholder="Ask about your codebase, docs, or describe a multi-file task..."
    onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();send()}">
  </textarea>
  <div class="btn-row">
    <button class="primary" onclick="send()">Send</button>
    <button class="sec"     onclick="sendCmd('task')">Repo task</button>
    <button class="sec"     onclick="sendCmd('ingest')">Re-ingest</button>
    <button class="sec"     onclick="refreshGpu()">GPU status</button>
    <span class="status" id="status"></span>
  </div>
</div>
<script>
const vsc = acquireVsCodeApi();
let activeTools = new Set(["rag","repo","mem"]);
let responding  = false;
const _st = vsc.getState() || {};
let history = _st.history || [];
if (_st.activeTools) activeTools = new Set(_st.activeTools);

function saveState() {
  vsc.setState({ history: history.slice(-100), activeTools: [...activeTools] });
}
function restoreRenderedHistory() {
  const el = document.getElementById("history");
  history.filter(m => m.content).forEach(m => {
    const d = document.createElement("div");
    d.className = "msg " + m.role;
    d.textContent = m.content;
    el.appendChild(d);
  });
  if (el.lastChild) el.lastChild.scrollIntoView();
  document.querySelectorAll(".tchip").forEach(chip => {
    if (activeTools.has(chip.dataset.tool)) chip.classList.add("on");
    else chip.classList.remove("on");
  });
}
function toggleTool(el) {
  const t = el.dataset.tool;
  if (activeTools.has(t)) { activeTools.delete(t); el.classList.remove("on"); }
  else                     { activeTools.add(t);    el.classList.add("on");    }
  saveState();
}
function setStatus(s) { document.getElementById("status").innerHTML = s; }
function addMsg(role, text, badges) {
  history.push({ role, content: text }); saveState();
  const div = document.createElement("div");
  div.className = "msg " + role;
  if (role === "ai") div.id = "ai-streaming";
  div.textContent = text;
  if (badges && badges.length) {
    const row = document.createElement("div");
    row.className = "badge-row";
    badges.forEach(b => {
      const span = document.createElement("span");
      span.className = "tbadge"; span.textContent = b; row.appendChild(span);
    });
    div.appendChild(row);
  }
  document.getElementById("history").appendChild(div);
  div.scrollIntoView({ behavior: "smooth" });
  return div;
}
function appendToStreaming(text) {
  const el = document.getElementById("ai-streaming");
  if (el) { el.textContent += text; el.scrollIntoView({ behavior: "smooth" }); }
}
function send() {
  if (responding) return;
  const q = document.getElementById("q").value.trim();
  if (!q) return;
  document.getElementById("q").value = "";
  responding = true;
  addMsg("user", q);
  setStatus('<span class="spinner"></span>thinking...');
  // Include last 10 turns as conversation history for multi-turn context
  const hist = history.slice(-10).map(m => ({ role: m.role === "ai" ? "assistant" : "user", content: m.content }));
  vsc.postMessage({ cmd: "query", query: q, tools: [...activeTools], history: hist });
}
function sendCmd(cmd) {
  const q = document.getElementById("q").value.trim();
  document.getElementById("q").value = "";
  responding = true;
  if (q) addMsg("user", q);
  setStatus('<span class="spinner"></span>' + cmd + '...');
  vsc.postMessage({ cmd, query: q, tools: [...activeTools] });
}
function refreshGpu() { vsc.postMessage({ cmd: "gpu_status" }); }

window.addEventListener("message", e => {
  const m = e.data;
  if (m.type === "stream_start") {
    const sd = document.createElement("div");
    sd.className = "msg ai"; sd.id = "ai-streaming";
    document.getElementById("history").appendChild(sd);
    sd.scrollIntoView({ behavior: "smooth" });
  }
  if (m.type === "stream_chunk") appendToStreaming(m.text);
  if (m.type === "stream_end") {
    const streamEl = document.getElementById("ai-streaming");
    if (streamEl) {
      history.push({ role: "ai", content: streamEl.textContent }); saveState();
      streamEl.id = "";
      if (m.badges && m.badges.length) {
        const br = document.createElement("div");
        br.className = "badge-row";
        m.badges.forEach(b => {
          const s = document.createElement("span");
          s.className = "tbadge"; s.textContent = b; br.appendChild(s);
        });
        streamEl.appendChild(br);
      }
    }
    responding = false; setStatus("done");
  }
  if (m.type === "status") setStatus(m.text);
  if (m.type === "error") {
    addMsg("ai", "Error: " + m.text);
    responding = false; setStatus("error");
  }
  if (m.type === "gpu_update") {
    const bar = document.getElementById("gpu-bar");
    if (m.error) {
      bar.textContent = "â¬¡ GPU: " + m.error;
    } else {
      bar.textContent = "â¬¡ " + (m.name||"GPU") +
        " | VRAM: " + (m.mem_used_mb||"?") + "/" + (m.mem_total_mb||"?") +
        " MB | Util: " + (m.gpu_util_pct||"?") + "%";
    }
  }
});
restoreRenderedHistory();
setInterval(() => vsc.postMessage({ cmd: "gpu_status" }), 30000);
</script>
</body>
</html>`;
}

// â”€â”€ Chat participant (@rag) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
async function handleChatRequest(request, _context, stream, token) {
  const ws          = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
  const editor      = vscode.window.activeTextEditor;
  const currentFile = editor ? vscode.workspace.asRelativePath(editor.document.uri) : null;
  const query       = request.prompt.trim();
  const cmd         = request.command;
  let toolBadges    = [];

  if (cmd === "task") {
    stream.progress("Indexing repo...");
    const result = await repoTask(ws, query, currentFile);
    stream.markdown("**Plan**\n");
    (result.plan || []).forEach((s, i) =>
      stream.markdown(`${i+1}. ${s.description} â†’ \`${(s.files_affected||[]).join(", ")}\`\n`));
    if ((result.edits || []).length > 0) {
      stream.markdown(`\n**${result.edits.length} file edits proposed**\n`);
      result.edits.forEach(ed =>
        stream.markdown(`- \`${ed.file}\` (L${ed.start_line}â€“${ed.end_line}): ${ed.description}\n`));
      const apply = await vscode.window.showQuickPick(["Apply all edits","Preview only"],
                          { placeHolder: result.summary });
      if (apply === "Apply all edits") {
        await applyEdits(result.edits, ws);
        stream.markdown("\nâœ“ Edits applied.");
      }
    }
    stream.markdown(`\n*${result.summary}*`);
    return;
  }

  if (cmd === "ingest") {
    const t = vscode.window.createTerminal("RAG Ingest");
    t.sendText(`cd "${ws}" && python ingest.py`);
    t.show();
    stream.markdown("Re-ingesting docs â€“ check the terminal.");
    return;
  }

  stream.progress("Searching knowledge base...");
  const ragContext = await ragRetrieve(query);
  if (ragContext) toolBadges.push("Hybrid RAG");

  // Route through agentic /query -- intent detection + real tool execution
  stream.progress("Running tools (intent dispatch active)...");
  // Build history from VS Code chat context (previous turns in this conversation)
  const chatHistory = (_context.history || []).flatMap(turn => {
    const msgs = [];
    if (turn.participant) msgs.push({ role: "assistant", content: turn.response?.map(r => r.value || "").join("") || "" });
    if (turn.prompt)      msgs.push({ role: "user",      content: turn.prompt });
    return msgs;
  }).filter(m => m.content).slice(-10);
  try {
    const result  = await httpPost(ragUrl(), "/query", { query, history: chatHistory });
    const answer  = result.answer || "(no answer)";
    const toolMap = { web: "Web search", docs: "Hybrid RAG",
                       diagnosis: "Self-Diagnosis", audio: "Audio transcription",
                       ocr: "Image OCR" };
    const used    = (result.tools_used || []).map(t => toolMap[t] || t);
    if (result.memory_hits > 0) used.push(`Memory (${result.memory_hits})`);
    used.push("Model: " + model());
    stream.markdown(answer);
    stream.markdown(`\n\n---\n*Tools used: ${used.join(", ")}*`);
    toolBadges.push(...used);
  } catch (err) {
    // Backend unreachable — attempt auto-restart then surface a clear error
    const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (ws) {
      stream.markdown("**⚠️ Backend offline — attempting auto-start…**\n\n");
      await ensureServerRunning(ws);
      // Retry the query once after auto-start
      try {
        const result2 = await httpPost(ragUrl(), "/query",
          { query: query, history: [] });
        const answer2 = result2.answer || "(no answer)";
        const toolMap2 = { web: "Web search", docs: "Hybrid RAG",
                           diagnosis: "Self-Diagnosis", audio: "Audio transcription",
                           ocr: "Image OCR" };
        const used2 = (result2.tools_used || []).map(t => toolMap2[t] || t);
        if (result2.memory_hits > 0) used2.push(`Memory (${result2.memory_hits})`);
        used2.push("Model: " + model());
        stream.markdown(answer2);
        stream.markdown(`\n\n---\n*Tools used: ${used2.join(", ")}*`);
        toolBadges.push(...used2);
        return;
      } catch {}
    }
    stream.markdown(
      "**⚠️ Cognitive RAG backend is offline** (could not reach `http://localhost:8765`).\n\n" +
      "Audio transcription, web search, OCR, and all agentic tools require the backend.\n\n" +
      "**Auto-start attempted** — if it still fails, check that the workspace folder " +
      "contains a `.venv` directory.\n\n" +
      `*Error: ${err.message}*`
    );
    toolBadges.push("Backend OFFLINE");
  }
}

// â”€â”€ Sidebar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function registerSidebar(context) {
  const provider = {
    resolveWebviewView(view) {
      view.webview.options = { enableScripts: true };
      view.webview.html    = getSidebarHtml(model());

      view.webview.onDidReceiveMessage(async msg => {
        const ws     = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
        const editor = vscode.window.activeTextEditor;
        const cf     = editor ? vscode.workspace.asRelativePath(editor.document.uri) : null;
        const post   = t => view.webview.postMessage(t);

        // FIX-12: GPU status now uses httpGet (proper GET)
        if (msg.cmd === "gpu_status") {
          try {
            const gs = await httpGet(ragUrl(), "/gpu_status");
            post({ type: "gpu_update", ...gs });
          } catch (e) {
            post({ type: "gpu_update", error: e.message });
          }
          return;
        }

        if (msg.cmd === "ingest") {
          const t = vscode.window.createTerminal("RAG Ingest");
          t.sendText(`cd "${ws}" && python ingest.py`);
          t.show();
          post({ type: "status", text: "ingestion started in terminal" });
          return;
        }

        if (msg.cmd === "task") {
          post({ type: "status", text: "planning..." });
          const result = await repoTask(ws, msg.query || "Analyse the current file", cf);
          let out = "**Plan**\n";
          (result.plan || []).forEach((s, i) => { out += `${i+1}. ${s.description}\n`; });
          out += `\n**${(result.edits || []).length} edits proposed**\n`;
          (result.edits || []).forEach(ed => { out += `- \`${ed.file}\`: ${ed.description}\n`; });
          post({ type: "stream_start" });
          post({ type: "stream_chunk", text: out });
          post({ type: "stream_end",   badges: ["Repo graph"] });
          if ((result.edits || []).length > 0) {
            const pick = await vscode.window.showQuickPick(["Apply all edits","Preview only"],
                              { placeHolder: result.summary });
            if (pick === "Apply all edits") {
              await applyEdits(result.edits, ws);
              vscode.window.showInformationMessage("Applied " + result.edits.length + " edits");
            }
          }
          return;
        }

        // Default query — route through agentic /query for tool dispatch
        const q = msg.query;
        if (!q) return;
        post({ type: "stream_start" });
        post({ type: "status", text: "running tools..." });
        try {
          const result = await httpPost(ragUrl(), "/query", { query: q, history: msg.history || [] });
          const answer = result.answer || "(no answer)";
          const toolMap = { web: "Web search", docs: "Hybrid RAG",
                            diagnosis: "Self-Diagnosis", audio: "Audio transcription",
                            ocr: "Image OCR" };
          const badges = (result.tools_used || []).map(t => toolMap[t] || t);
          if (result.memory_hits > 0) badges.push(`Memory (${result.memory_hits})`);
          badges.push("Model: " + model());
          post({ type: "stream_chunk", text: answer });
          post({ type: "stream_end",   badges });
        } catch (err) {
          post({ type: "error",
                 text: "RAG server error: " + err.message +
                       ". Make sure the backend is running on port 8765." });
        }
      });
    }
  };

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("cognitiveRag.sidebar", provider,
      { webviewOptions: { retainContextWhenHidden: true } })
  );
}

// ─── Auto-start backend server ────────────────────────────────────────────────
let _serverProc = null;

async function _checkHealth(url) {
  return new Promise(resolve => {
    const parsed = new URL(url + "/health");
    const lib    = parsed.protocol === "https:" ? https : http;
    const req    = lib.get({ hostname: parsed.hostname, port: parsed.port || 80,
                             path: parsed.pathname, timeout: 2000 }, res => {
      resolve(res.statusCode === 200);
    });
    req.on("error", () => resolve(false));
    req.on("timeout", () => { req.destroy(); resolve(false); });
  });
}

async function ensureServerRunning(wsRoot) {
  if (await _checkHealth(ragUrl())) return; // already up

  const candidates = [
    path.join(wsRoot, ".venv", "Scripts", "python.exe"),  // Windows venv
    path.join(wsRoot, ".venv", "bin", "python"),           // Unix venv
  ];
  const pyExe = candidates.find(p => fs.existsSync(p));
  if (!pyExe) {
    vscode.window.showWarningMessage(
      "Cognitive RAG: backend not running and .venv not found in workspace. " +
      "Run start_server.ps1 manually.");
    return;
  }

  vscode.window.showInformationMessage("Cognitive RAG: starting backend server…");
  _serverProc = cp.spawn(pyExe,
    ["-m", "uvicorn", "server.api:app", "--host", "0.0.0.0", "--port", "8765"],
    { cwd: wsRoot, detached: false, stdio: "ignore" });
  _serverProc.on("error", err =>
    vscode.window.showErrorMessage("Cognitive RAG: failed to start server: " + err.message));

  // Poll health up to 25 s
  for (let i = 0; i < 25; i++) {
    await new Promise(r => setTimeout(r, 1000));
    if (await _checkHealth(ragUrl())) {
      vscode.window.showInformationMessage("Cognitive RAG: backend ready ✓");
      return;
    }
  }
  vscode.window.showWarningMessage("Cognitive RAG: server started but health check timed out.");
}

// ─── activate ─────────────────────────────────────────────────────────────────
function activate(context) {
  // Auto-start the backend if it's not already running
  const wsRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  if (wsRoot) ensureServerRunning(wsRoot);

  registerInlineCompletions(context);

  if (vscode.chat && vscode.chat.createChatParticipant) {
    const participant = vscode.chat.createChatParticipant("cognitiveRag.chat", handleChatRequest);
    participant.iconPath = vscode.Uri.joinPath(context.extensionUri, "media", "icon.png");
    context.subscriptions.push(participant);
  }

  registerSidebar(context);

  context.subscriptions.push(
    vscode.commands.registerCommand("cognitiveRag.openChat", () => {
      vscode.commands.executeCommand("workbench.action.chat.open", { query: "@rag " });
    }),
    vscode.commands.registerCommand("cognitiveRag.repoTask", async () => {
      const ws     = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      const editor = vscode.window.activeTextEditor;
      if (!ws) return vscode.window.showErrorMessage("Open a workspace first.");
      const task = await vscode.window.showInputBox({ prompt: "Describe the repo task" });
      if (!task) return;
      const result = await repoTask(ws, task,
        editor ? vscode.workspace.asRelativePath(editor.document.uri) : null);
      const panel = vscode.window.createWebviewPanel("repoTask",
        "Repo Task: " + task.slice(0, 40), vscode.ViewColumn.Two, { enableScripts: false });
      const esc = s => String(s)
        .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
      let html = `<style>body{font-family:var(--vscode-font-family,sans-serif);
        padding:16px;font-size:13px;color:var(--vscode-foreground);
        background:var(--vscode-editor-background)}
        h2{margin:16px 0 8px;font-size:14px;font-weight:600}
        li{padding:3px 0;line-height:1.5}
        code{background:var(--vscode-textCodeBlock-background,#eee);padding:1px 5px;
             border-radius:3px;font-size:11px}
        details{margin:4px 0;border:1px solid var(--vscode-panel-border,#ccc);border-radius:4px}
        summary{padding:6px 10px;cursor:pointer;font-weight:500;list-style:none}
        pre{padding:10px;margin:0;overflow:auto;font-size:11px;line-height:1.4;
            background:var(--vscode-textCodeBlock-background,#f5f5f5)}
        em{display:block;margin-top:14px;font-size:11px;opacity:.6;
           border-top:1px solid var(--vscode-panel-border,#eee);padding-top:8px}</style>`;
      html += "<h2>Plan</h2><ul>";
      (result.plan||[]).forEach((s,i) => {
        html += `<li><b>${i+1}.</b> ${esc(s.description)} <code>${
          (s.files_affected||[]).map(esc).join(", ")}</code></li>`;
      });
      html += `</ul><h2>Edits (${(result.edits||[]).length})</h2>`;
      (result.edits||[]).forEach(ed => {
        html += `<details><summary><code>${esc(ed.file)}</code> L${ed.start_line}â€“${
          ed.end_line} â€“ ${esc(ed.description)}</summary><pre>${esc(ed.text)}</pre></details>`;
      });
      html += `<em>${esc(result.summary||"")}</em>`;
      panel.webview.html = html;
      if ((result.edits||[]).length > 0) {
        const pick = await vscode.window.showQuickPick(["Apply all edits","Preview only"]);
        if (pick === "Apply all edits") await applyEdits(result.edits, ws);
      }
    }),
    vscode.commands.registerCommand("cognitiveRag.ingestDocs", () => {
      const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
      const t  = vscode.window.createTerminal("RAG Ingest");
      t.sendText(`cd "${ws}" && python ingest.py`);
      t.show();
    }),
    vscode.commands.registerCommand("cognitiveRag.runTests", () => {
      const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || "";
      const t  = vscode.window.createTerminal("RAG Tests");
      t.sendText(`cd "${ws}" && python -m pytest tests/ -v --tb=short`);
      t.show();
    })
  );

  vscode.window.showInformationMessage(
    `Cognitive RAG v17 active â€“ model: ${model()}. Ghost text inline completions enabled.`
  );
}

function deactivate() {
  if (_serverProc) { _serverProc.kill(); _serverProc = null; }
}
module.exports = { activate, deactivate };
