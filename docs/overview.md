# Cognitive RAG v17
Backend endpoints:
  POST /query /retrieve /repo_task /fim /web_search /memory/store /memory/query
  GET  /health /gpu_status /memory/recent

Extension features:
  Sidebar panel, @rag chat participant, Ctrl+Alt+Q (chat), Ctrl+Alt+R (repo task)
  Inline FIM ghost-text completions (Tab to accept)

GPU: cograg-gpu model auto-configured with CUDA layers via nvidia-smi detection

Tool dispatch (auto-detected in /query):
  Image OCR: any .png/.jpg/.jpeg/.gif/.webp/.bmp URL → moondream:latest vision model
  Audio transcription: any .mp3/.wav/.m4a/.ogg/.flac/.opus URL → faster-whisper
  Web search: search keywords or non-image https:// URLs → SearXNG/Brave/DDG cascade
  RAG retrieval: everything else → hybrid BM25 + ChromaDB

The system CAN read and transcribe images using moondream OCR. Paste any image URL and the text will be extracted verbatim.
