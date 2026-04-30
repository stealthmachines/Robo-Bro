"""
Audio transcription using faster-whisper (local, no cloud dependency).
Supports file paths and direct URLs. Auto-selects GPU if CUDA is available.

Large-file strategy: faster_whisper's feature extractor runs STFT on the whole
audio array before chunking, which requires ~1 GB RAM for a 55-min podcast.
Fix: pre-split via ffmpeg into 5-minute WAV chunks, transcribe each, merge.
"""
import os, math, subprocess, tempfile
from pathlib import Path

_MODEL          = None   # GPU (or auto) model
_CPU_MODEL      = None   # CPU fallback model
_MODEL_SIZE     = os.environ.get("WHISPER_MODEL", "base")   # tiny/base/small/medium/large
# CPU fallback always uses tiny — smaller BLAS workspace, fits in constrained RAM
_CPU_MODEL_SIZE = os.environ.get("WHISPER_CPU_MODEL", "tiny")
_FFMPEG         = os.environ.get("FFMPEG_PATH", r"c:\programdata\chocolatey\bin\ffmpeg.exe")
_CHUNK_SECS     = 300    # 5-minute chunks for large files

# Limit MKL/OpenMP threads before any model loads to prevent mkl_malloc OOM
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")

def _get_model(force_cpu=False):
    global _MODEL, _CPU_MODEL
    from faster_whisper import WhisperModel
    if force_cpu:
        if _CPU_MODEL is None:
            # tiny model + cpu_threads=1 keeps MKL workspace small enough to fit in RAM
            _CPU_MODEL = WhisperModel(
                _CPU_MODEL_SIZE, device="cpu", compute_type="float32", cpu_threads=1
            )
        return _CPU_MODEL
    if _MODEL is None:
        try:
            import ctranslate2
            device  = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
            compute = "float16" if device == "cuda" else "float32"
        except Exception:
            device, compute = "cpu", "float32"
        _MODEL = WhisperModel(_MODEL_SIZE, device=device, compute_type=compute)
    return _MODEL


def _get_duration(path: str) -> float:
    """Return audio duration in seconds via ffprobe. Returns 9999 on failure."""
    ffprobe = _FFMPEG.replace("ffmpeg.exe", "ffprobe.exe")
    try:
        r = subprocess.run(
            [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=30,
        )
        import json
        return float(json.loads(r.stdout)["format"]["duration"])
    except Exception:
        return 9999.0


def _transcribe_chunked(path: str, model, language=None) -> dict:
    """Split a large audio file into _CHUNK_SECS-second WAV slices and transcribe each."""
    duration = _get_duration(path)
    n_chunks = math.ceil(duration / _CHUNK_SECS)
    all_segs, all_text, lang = [], [], None

    for i in range(n_chunks):
        start = i * _CHUNK_SECS
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            chunk_path = tf.name
        try:
            subprocess.run(
                [
                    _FFMPEG, "-y",
                    "-ss", str(start), "-t", str(_CHUNK_SECS),
                    "-i", path,
                    "-ar", "16000", "-ac", "1",
                    chunk_path,
                ],
                capture_output=True, check=True, timeout=120,
            )
            segs, info = model.transcribe(
                chunk_path,
                beam_size=5,
                language=language,
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
            )
            if lang is None:
                lang = info.language
            for s in segs:
                t = s.text.strip()
                all_segs.append({"start": s.start + start, "end": s.end + start, "text": t})
                if t:
                    all_text.append(t)
        finally:
            try:
                os.unlink(chunk_path)
            except OSError:
                pass

    return {"text": " ".join(all_text), "language": lang or "unknown", "segments": all_segs}


def transcribe_file(path: str, language: str = None) -> dict:
    """Transcribe an audio or video file.

    Returns:
        {"text": str, "language": str, "segments": list}

    For files longer than _CHUNK_SECS seconds the file is split via ffmpeg so
    that faster_whisper's STFT never processes more than one chunk at a time.
    """
    def _run(model):
        # Fast path: let faster_whisper handle short files directly
        duration = _get_duration(path)
        if duration > _CHUNK_SECS:
            return _transcribe_chunked(path, model, language)
        segments, info = model.transcribe(
            path,
            beam_size=5,
            language=language,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 500},
        )
        seg_list = [{"start": s.start, "end": s.end, "text": s.text.strip()} for s in segments]
        full_text = " ".join(s["text"] for s in seg_list)
        return {"text": full_text, "language": info.language, "segments": seg_list}

    try:
        return _run(_get_model())
    except (RuntimeError, OSError) as e:
        err = str(e).lower()
        if "cublas" in err or "cuda" in err or "dll" in err:
            import warnings
            warnings.warn(f"faster-whisper CUDA error ({e}); retrying on CPU.")
            return _run(_get_model(force_cpu=True))
        raise
    except MemoryError:
        # numpy ArrayMemoryError — file too large for single-shot STFT; use chunks
        return _transcribe_chunked(path, _get_model(force_cpu=True), language)

def transcribe_url(url: str, language: str = None) -> dict:
    """Download audio/video from a URL, transcribe, and return result dict."""
    import requests
    r = requests.get(url, timeout=60, stream=True,
                     headers={"User-Agent": "cognitive-rag/1.7"})
    r.raise_for_status()
    suffix = Path(url.split("?")[0]).suffix or ".mp3"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        for chunk in r.iter_content(65536):
            f.write(chunk)
        tmp = f.name
    try:
        return transcribe_file(tmp, language=language)
    finally:
        os.unlink(tmp)
