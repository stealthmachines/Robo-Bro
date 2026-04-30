Set-Location "C:\Users\Owner\cognitive-rag-v17"
Write-Host "Running Cognitive RAG v17 tests..." -ForegroundColor Cyan
& "C:\Users\Owner\cognitive-rag-v17\.venv\Scripts\Activate.ps1"
& "C:\Users\Owner\cognitive-rag-v17\.venv\Scripts\python.exe" -m pytest tests/ -v --tb=short 2>&1
