Set-Location "C:\Users\Owner\cognitive-rag-v17"
Write-Host "Cognitive RAG v17 | Model: cograg-gpu | GPU: NVIDIA GeForce RTX 2060" -ForegroundColor Cyan
Write-Host "API: http://127.0.0.1:8765" -ForegroundColor Green
Write-Host "Test: .\run_tests.ps1" -ForegroundColor DarkCyan

# Ensure Ollama is running
if (-not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep 3
    Write-Host "  Ollama started." -ForegroundColor DarkGray
}

# Activate venv
& "C:\Users\Owner\cognitive-rag-v17\.venv\Scripts\Activate.ps1"

# Watchdog loop: restart backend if it crashes
$restarts = 0
while ($true) {
    $restarts++
    if ($restarts -gt 1) {
        Write-Host ("[{0}] Backend crashed — restarting (attempt {1})..." -f (Get-Date -Format "HH:mm:ss"), $restarts) -ForegroundColor Yellow
        Start-Sleep 2
    }
    Write-Host ("[{0}] Starting backend (run #{1})..." -f (Get-Date -Format "HH:mm:ss"), $restarts) -ForegroundColor Green
    & "C:\Users\Owner\cognitive-rag-v17\.venv\Scripts\python.exe" -m uvicorn server.api:app --host 127.0.0.1 --port 8765 --reload
    # If we reach here the process exited — loop restarts it
}
