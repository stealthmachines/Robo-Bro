import re

with open("vscode-extension/extension.js", encoding="utf-8") as f:
    content = f.read()

# Find the block from 'let webContext' to the closing } of handleChatRequest
# We'll use a marker-based replacement anchored on unique strings

OLD_START = '  let webContext = "";\n  const webTriggers'
OLD_END_MARKER = '  }\n}\n\n// '  # closing of handleChatRequest + Sidebar comment

# Find bounds
start_idx = content.find(OLD_START)
if start_idx == -1:
    print("ERROR: could not find OLD_START")
    exit(1)

# Find the closing } of handleChatRequest — it's "  }\n}\n\n// "
end_idx = content.find(OLD_END_MARKER, start_idx)
if end_idx == -1:
    print("ERROR: could not find OLD_END_MARKER")
    exit(1)

# The end_idx points at '  }' — we want to keep "\n}\n\n// " so the splice ends AFTER the two closing braces
# We replace from OLD_START up to and including "  }\n}\n"
end_splice = end_idx + len("  }\n}")

old_block = content[start_idx:end_splice]
print("=== OLD BLOCK (first 200 chars) ===")
print(repr(old_block[:200]))
print("=== OLD BLOCK (last 100 chars) ===")
print(repr(old_block[-100:]))

new_block = '''  // Route through agentic /query -- intent detection + real tool execution
  stream.progress("Running tools (intent dispatch active)...");
  try {
    const result  = await httpPost(ragUrl(), "/query", { query });
    const answer  = result.answer || "(no answer)";
    const toolMap = { web: "Web search", docs: "Hybrid RAG", diagnosis: "Self-Diagnosis" };
    const used    = (result.tools_used || []).map(t => toolMap[t] || t);
    if (result.memory_hits > 0) used.push(`Memory (${result.memory_hits})`);
    used.push("Model: " + model());
    stream.markdown(answer);
    stream.markdown(`\\n\\n---\\n*Tools used: ${used.join(", ")}*`);
    toolBadges.push(...used);
  } catch (err) {
    // Fallback: direct Ollama with RAG context if backend unreachable
    const sysPrompt = [
      "You are a local coding assistant backed by a hybrid RAG system.",
      "Use the provided context to answer accurately. Be concise.",
      currentFile ? `Current file: ${currentFile}` : "",
      ws ? `Workspace: ${ws}` : ""
    ].filter(Boolean).join("\\n");
    const msgs = [
      { role: "system", content: sysPrompt },
      ...(ragContext ? [{ role: "system", content: "RETRIEVED CONTEXT:\\n\\n" + ragContext }] : []),
      { role: "user", content: query }
    ];
    stream.progress("Falling back to direct Ollama...");
    await streamOllama(msgs, chunk => stream.markdown(chunk));
    toolBadges.push("Model: " + model() + " (fallback)");
  }
}'''

new_content = content[:start_idx] + new_block + content[end_splice:]
with open("vscode-extension/extension.js", "w", encoding="utf-8") as f:
    f.write(new_content)
print("SUCCESS: extension.js patched")
