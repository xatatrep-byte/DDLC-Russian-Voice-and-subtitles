from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import os
import queue
import re
import sys
import threading
import time
import traceback
import wave
from pathlib import Path

import numpy as np
import torch

try:
    import winsound
except ImportError:
    winsound = None

ENGINE_VERSION = "ddlc-neural-v0.5.2.3-natural-dashes-all-silero-v5_5_ru"
SAMPLE_RATE = 48000

ROOT = Path(__file__).resolve().parent
MODEL_PATH = ROOT / "models" / "v5_5_ru.pt"
CACHE_DIR = ROOT / "cache"
LOG_PATH = ROOT / "neural.log"
FAILED_FLAG = ROOT / "failed.flag"
RUNTIME_READY_FLAG = ROOT / "runtime-ready.flag"

# Three dedicated female voices plus distinct SSML prosody.
# Silero v5_5_ru currently exposes 3 female + 2 male Russian speakers.
PROFILES = {
    # User-defined character archetypes.
    # No voice cloning and no lexical emotion classifier.
    "sayori": {
        # Cute, small, slightly squeaky. Do not keep pitch="high" permanently:
        # earlier tests showed that this can make Baya sound strained/hoarse.
        "voice": "baya",
        "pitch": "medium",
        "rate": "fast",
    },
    "natsuki": {
        # Cute small girl, but less squeaky than Sayori.
        "voice": "kseniya",
        "pitch": "medium",
        "rate": "fast",
    },
    "yuri": {
        # Cute and only slightly slower. No compounded slowdown.
        "voice": "xenia",
        "pitch": "medium",
        "rate": "slow",
    },
    "monika": {
        # More restrained/mature, but not slow.
        "voice": "baya",
        "pitch": "medium",
        "rate": "medium",
    },
    "mc": {
        # Roughly a 16-year-old boy: avoid the adult-sounding low preset.
        "voice": "aidar",
        "pitch": "medium",
        "rate": "medium",
    },
    "narrator": {
        "voice": "eugene",
        "pitch": "medium",
        "rate": "medium",
    },
    "other": {
        "voice": "baya",
        "pitch": "medium",
        "rate": "medium",
    },
}


def log(message: str) -> None:
    try:
        ROOT.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(f"[{stamp}] {message}\n")
    except Exception:
        pass


def stop_audio() -> None:
    if winsound is None:
        return
    try:
        winsound.PlaySound(None, 0)
    except Exception:
        pass


def _profile_for_line(speaker: str, text: str) -> dict[str, str]:
    """
    Very small deterministic style layer.
    Only character identity and punctuation affect delivery.
    """
    base = PROFILES.get(speaker, PROFILES["other"])
    pitch = base["pitch"]
    rate = base["rate"]

    exclam = text.count("!")
    question = "?" in text

    if speaker == "sayori":
        # Slight squeak comes from expressive lines, not a permanent strained pitch.
        if exclam or question:
            pitch = "high"
        rate = "fast"

    elif speaker == "natsuki":
        # Energetic and childlike, but less high-pitched than Sayori.
        pitch = "medium"
        rate = "fast"

    elif speaker == "yuri":
        # Exactly one gentle slowdown level.
        pitch = "medium"
        rate = "slow"

    elif speaker == "monika":
        # Restrained: punctuation does not suddenly turn her into Sayori.
        pitch = "medium"
        rate = "medium"

    elif speaker == "mc":
        # Young male, not a deep adult baritone.
        pitch = "medium"
        rate = "fast" if exclam >= 2 else "medium"

    return {
        "voice": base["voice"],
        "pitch": pitch,
        "rate": rate,
    }


def _stable_pause_ms(
    speaker: str,
    text: str,
    chunk_index: int,
    base_ms: int,
    spread_ms: int = 14,
) -> int:
    """
    Tiny deterministic timing variation.

    Same speaker + same line + same chunk always produces the same pause.
    This avoids a metronomic cadence without making playback random.
    """
    key = f"{ENGINE_VERSION}|{speaker}|{text}|{chunk_index}|pause".encode("utf-8")
    value = int(hashlib.sha256(key).hexdigest()[:8], 16)
    delta = (value % (spread_ms * 2 + 1)) - spread_ms
    return max(20, base_ms + delta)


def _split_acting_chunks(text: str) -> list[tuple[str, str]]:
    """
    Split a DDLC line into small punctuation-aware pieces.

    Returned kind values:
      clause, comma, dash, ellipsis, exclaim, question, stop

    Punctuation is kept in the spoken clause when useful and also emits
    a short pause after the clause.
    """
    # Em/en dash always count as punctuation. ASCII "-" counts as a dash
    # only when surrounded by spaces, so words like "кто-то" stay intact.
    pattern = re.compile(r"(\.\.\.|…|[!?]+|[.,;:]|[—–]|(?<=\s)-(?=\s))")
    parts = pattern.split(text)

    chunks: list[tuple[str, str]] = []
    pending = ""

    for part in parts:
        if not part:
            continue

        if part in ("...", "…"):
            if pending.strip():
                chunks.append(("clause", pending.strip()))
                pending = ""
            chunks.append(("ellipsis", part))
            continue

        if re.fullmatch(r"[!?]+", part):
            if pending.strip():
                kind = "question" if "?" in part and "!" not in part else "exclaim"
                if "?" in part and "!" in part:
                    kind = "question"
                chunks.append((kind, pending.strip() + part))
                pending = ""
            else:
                chunks.append(("question" if "?" in part else "exclaim", part))
            continue

        if part == ".":
            if pending.strip():
                chunks.append(("stop", pending.strip() + "."))
                pending = ""
            continue

        if part in (",", ";", ":"):
            if pending.strip():
                chunks.append(("comma", pending.strip() + part))
                pending = ""
            continue

        if part in ("—", "–", "-"):
            if pending.strip():
                chunks.append(("clause", pending.strip()))
                pending = ""
            chunks.append(("dash", part))
            continue

        pending += part

    if pending.strip():
        chunks.append(("clause", pending.strip()))

    return chunks


def _chunk_style(
    speaker: str,
    kind: str,
    base_profile: dict[str, str],
) -> tuple[str, str]:
    """
    Character-specific local prosody.

    Only a small set of Silero-safe qualitative pitch/rate levels is used.
    The goal is acting, not voice transformation.
    """
    pitch = base_profile["pitch"]
    rate = base_profile["rate"]

    if speaker == "sayori":
        # Cute, small, slightly squeaky: expressive endings lift briefly,
        # while normal words stay natural instead of permanently high.
        if kind in ("exclaim", "question"):
            pitch = "high"
            rate = "fast"
        elif kind == "comma":
            pitch = "medium"
            rate = "fast"

    elif speaker == "natsuki":
        # Energetic but deliberately less squeaky than Sayori.
        pitch = "medium"
        rate = "fast"
        if kind == "exclaim":
            rate = "fast"

    elif speaker == "monika":
        # Controlled, confident and fluid. Avoid cartoon-like pitch jumps.
        pitch = "medium"
        rate = "medium"

    elif speaker == "yuri":
        # Cute, soft and only slightly slow. Questions get a gentle lift,
        # but never an extra slowdown layer.
        pitch = "high" if kind == "question" else "medium"
        rate = "slow"

    elif speaker == "mc":
        # Teen boy: emotional lines become a little quicker, not deeper.
        pitch = "medium"
        rate = "fast" if kind == "exclaim" else "medium"

    return pitch, rate


def _pause_for_kind(
    speaker: str,
    kind: str,
    text: str,
    chunk_index: int,
) -> int:
    # Base pauses are intentionally modest so dialogue stays responsive.
    base = {
        "comma": 85,
        "dash": 25,
        "ellipsis": 285,
        "exclaim": 105,
        "question": 120,
        "stop": 125,
        "clause": 0,
    }.get(kind, 0)

    # Character cadence.
    if speaker == "sayori":
        if kind in ("comma", "exclaim"):
            base -= 15
        elif kind == "ellipsis":
            base = 245

    elif speaker == "natsuki":
        if kind in ("comma", "exclaim", "question"):
            base -= 18
        elif kind == "ellipsis":
            base = 240

    elif speaker == "monika":
        if kind == "comma":
            base = 82
        elif kind == "ellipsis":
            base = 265

    elif speaker == "yuri":
        if kind == "comma":
            base = 110
        elif kind == "ellipsis":
            base = 345
        elif kind in ("question", "stop"):
            base += 15

    elif speaker == "mc":
        if kind == "comma":
            base = 88
        elif kind == "ellipsis":
            base = 280

    if base <= 0:
        return 0

    return _stable_pause_ms(
        speaker=speaker,
        text=text,
        chunk_index=chunk_index,
        base_ms=base,
    )


def _merge_natural_dashes(
    chunks: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    """
    Keep ordinary spoken dashes inside a single prosody segment for ALL voices.

    Acting Lite originally split at a dash into:
        prosody(left) + break + prosody(right)

    Silero can already create a natural boundary from the dash punctuation
    itself. Splitting it into multiple prosody tags plus an explicit break can
    make the pause much longer than intended.

    So "left — right" is merged back into one spoken segment for every
    character. Only unusual standalone dash patterns remain separate.
    """
    out: list[tuple[str, str]] = []
    i = 0

    while i < len(chunks):
        if (
            i + 2 < len(chunks)
            and chunks[i][0] in ("clause", "comma")
            and chunks[i + 1][0] == "dash"
            and chunks[i + 2][0] in (
                "clause", "comma", "stop", "question", "exclaim"
            )
        ):
            _, left = chunks[i]
            _, dash = chunks[i + 1]
            right_kind, right = chunks[i + 2]

            # Preserve sentence-ending classification from the right-hand side
            # so the normal end-of-sentence pause still applies.
            merged_kind = right_kind if right_kind != "clause" else "clause"
            merged_text = left.rstrip(",;: ") + " " + dash + " " + right.lstrip()
            out.append((merged_kind, merged_text))
            i += 3
            continue

        out.append(chunks[i])
        i += 1

    return out



def make_ssml(
    text: str,
    profile: dict[str, str],
    speaker: str = "other",
) -> str:
    """
    Acting Lite renderer.

    Instead of one prosody setting for the whole line, each punctuation-aware
    chunk receives a small local pitch/rate decision and a natural pause.
    """
    chunks = _split_acting_chunks(text)

    # A normal written dash should not create a theatrical stop for any voice.
    chunks = _merge_natural_dashes(chunks)

    if not chunks:
        safe = html.escape(text, quote=False)
        return (
            "<speak>"
            f'<prosody pitch="{profile["pitch"]}" rate="{profile["rate"]}">'
            f"{safe}"
            "</prosody>"
            "</speak>"
        )

    pieces: list[str] = ["<speak>"]

    for index, (kind, raw) in enumerate(chunks):
        if kind == "ellipsis":
            pause = _pause_for_kind(speaker, kind, text, index)
            pieces.append(f'<break time="{pause}ms"/>')
            continue

        if kind == "dash":
            pause = _pause_for_kind(speaker, kind, text, index)
            pieces.append(f'<break time="{pause}ms"/>')
            continue

        safe = html.escape(raw, quote=False)
        pitch, rate = _chunk_style(speaker, kind, profile)

        pieces.append(
            f'<prosody pitch="{pitch}" rate="{rate}">{safe}</prosody>'
        )

        pause = _pause_for_kind(speaker, kind, text, index)
        if pause:
            pieces.append(f'<break time="{pause}ms"/>')

    pieces.append("</speak>")
    return "".join(pieces)



def cache_path(speaker: str, text: str) -> Path:
    p = _profile_for_line(speaker, text)
    identity = "\n".join(
        [
            ENGINE_VERSION,
            speaker,
            p["voice"],
            p["pitch"],
            p["rate"],
            text,
        ]
    )
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return CACHE_DIR / speaker / f"{digest}.wav"


def save_wav(path: Path, audio: torch.Tensor) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    if isinstance(audio, torch.Tensor):
        arr = audio.detach().float().cpu().numpy().reshape(-1)
    else:
        arr = np.asarray(audio, dtype=np.float32).reshape(-1)

    arr = np.nan_to_num(arr, nan=0.0, posinf=1.0, neginf=-1.0)
    arr = np.clip(arr, -1.0, 1.0)
    pcm = (arr * 32767.0).astype(np.int16)

    tmp = path.with_suffix(".tmp.wav")
    with wave.open(str(tmp), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm.tobytes())

    os.replace(str(tmp), str(path))


def play_wav(path: Path) -> None:
    if winsound is None:
        raise RuntimeError("winsound is unavailable; Windows is required")
    flags = winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT
    winsound.PlaySound(str(path), flags)


class NeuralEngine:
    def __init__(self) -> None:
        self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

        if not MODEL_PATH.is_file():
            raise FileNotFoundError(f"Silero model not found: {MODEL_PATH}")

        log(f"Loading model: {MODEL_PATH}")
        log(f"torch={torch.__version__}")
        log(f"cuda_available={torch.cuda.is_available()}")

        if torch.cuda.is_available():
            log(f"cuda_device={torch.cuda.get_device_name(0)}")
            try:
                log(f"cuda_capability={torch.cuda.get_device_capability(0)}")
            except Exception:
                pass
        else:
            log("WARNING CUDA unavailable; neural TTS will use CPU")

        importer = torch.package.PackageImporter(str(MODEL_PATH))
        self.model = importer.load_pickle("tts_models", "model")
        log(f"model_type={type(self.model).__name__}")
        log(
            "model_has_to=%s model_has_eval=%s"
            % (hasattr(self.model, "to"), hasattr(self.model, "eval"))
        )
        # Silero's packaged TTSModelMultiAcc_v3 wrapper supports .to(device),
        # but it is not itself a torch.nn.Module and does not expose .eval().
        # Keep compatibility with future wrappers that may expose eval().
        if hasattr(self.model, "to"):
            self.model.to(self.device)
        if hasattr(self.model, "eval"):
            self.model.eval()

        # Warm up the model once. This output is not played.
        profile = PROFILES["monika"]
        ssml = make_ssml("Проверка.", profile)
        with torch.inference_mode():
            _ = self.model.apply_tts(
                ssml_text=ssml,
                speaker=profile["voice"],
                sample_rate=SAMPLE_RATE,
            )

        if FAILED_FLAG.exists():
            FAILED_FLAG.unlink()

        RUNTIME_READY_FLAG.write_text(
            json.dumps(
                {
                    "engine": ENGINE_VERSION,
                    "device": str(self.device),
                    "gpu": (
                        torch.cuda.get_device_name(0)
                        if torch.cuda.is_available()
                        else None
                    ),
                    "torch": torch.__version__,
                    "sample_rate": SAMPLE_RATE,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

        log("Neural model ready")

    def synthesize(self, speaker: str, text: str) -> Path:
        profile = _profile_for_line(speaker, text)
        out = cache_path(speaker, text)

        if out.is_file() and out.stat().st_size > 44:
            log(
                f"CACHE HIT speaker={speaker} voice={profile['voice']} "
                f"chars={len(text)} file={out.name}"
            )
            return out

        ssml = make_ssml(text, profile, speaker=speaker)
        started = time.perf_counter()

        with torch.inference_mode():
            audio = self.model.apply_tts(
                ssml_text=ssml,
                speaker=profile["voice"],
                sample_rate=SAMPLE_RATE,
            )

        save_wav(out, audio)

        elapsed_ms = (time.perf_counter() - started) * 1000.0
        log(
            f"GENERATED speaker={speaker} voice={profile['voice']} "
            f"pitch={profile['pitch']} rate={profile['rate']} "
            f"chars={len(text)} ms={elapsed_ms:.1f} file={out.name}"
        )
        return out


class VoiceWorker:
    def __init__(self) -> None:
        self.q: queue.Queue[tuple[int, str, str] | None] = queue.Queue()
        self.seq_lock = threading.Lock()
        self.current_seq = 0
        self.engine: NeuralEngine | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def next_seq(self) -> int:
        with self.seq_lock:
            self.current_seq += 1
            return self.current_seq

    def get_seq(self) -> int:
        with self.seq_lock:
            return self.current_seq

    def submit(self, speaker: str, text: str) -> None:
        seq = self.next_seq()
        stop_audio()

        # Coalesce queued requests. The newest dialogue line wins.
        try:
            while True:
                self.q.get_nowait()
        except queue.Empty:
            pass

        self.q.put((seq, speaker, text))

    def stop(self) -> None:
        self.next_seq()
        stop_audio()

        try:
            while True:
                self.q.get_nowait()
        except queue.Empty:
            pass

    def shutdown(self) -> None:
        self.stop()
        self.q.put(None)

    def _run(self) -> None:
        try:
            self.engine = NeuralEngine()
        except Exception as exc:
            log(f"FATAL model initialization failed: {exc!r}")
            log(traceback.format_exc())
            try:
                FAILED_FLAG.write_text(
                    traceback.format_exc(), encoding="utf-8"
                )
            except Exception:
                pass
            return

        while True:
            item = self.q.get()
            if item is None:
                return

            seq, speaker, text = item

            if seq != self.get_seq():
                continue

            try:
                path = self.engine.synthesize(speaker, text)

                # If the player advanced while generation was running,
                # do not play the now-stale line.
                if seq != self.get_seq():
                    log(f"STALE SKIP speaker={speaker} chars={len(text)}")
                    continue

                play_wav(path)
                log(f"PLAY speaker={speaker} file={path.name}")

            except Exception as exc:
                log(f"ERROR synthesis/playback: {exc!r}")
                log(traceback.format_exc())


def decode_speak(line: str) -> tuple[str, str] | None:
    parts = line.split("|", 2)
    if len(parts) != 3:
        return None
    speaker = parts[1].strip() or "other"
    try:
        text = base64.b64decode(parts[2]).decode("utf-8", "replace")
    except Exception:
        return None
    text = " ".join(text.split()).strip()
    if not text:
        return None
    # DDLC lines are normally short; guard against accidental huge input.
    if len(text) > 1800:
        text = text[:1800]
    return speaker, text


def run_stdio() -> int:
    log("=== neural stdio host starting ===")
    worker = VoiceWorker()
    worker.start()

    for raw in sys.stdin:
        line = raw.rstrip("\r\n")

        if line == "STOP":
            worker.stop()
            continue

        if line == "QUIT":
            worker.shutdown()
            break

        if line.startswith("SPEAK|"):
            decoded = decode_speak(line)
            if decoded is not None:
                worker.submit(*decoded)

    worker.shutdown()
    log("stdio host stopped")
    return 0


def self_test(play: bool = True) -> int:
    log("=== self test ===")
    engine = NeuralEngine()

    samples = [
        ("sayori", "Привет! Я так рада тебя видеть, правда! Пойдём вместе?"),
        ("natsuki", "Эй, я просто решила тебе помочь! Не придумывай лишнего, ясно?"),
        ("yuri", "Если ты не против... я бы хотела немного почитать вместе. Можно?"),
        ("monika", "Добро пожаловать в литературный клуб. Надеюсь, тебе здесь понравится."),
        ("mc", "Ну... ладно. Думаю, я понял. Тогда пойдём вместе!"),
    ]

    for speaker, text in samples:
        path = engine.synthesize(speaker, text)
        print(f"{speaker}: {path}")
        if play:
            play_wav(path)
            # Let each preview be audible before the next one.
            time.sleep(3.2)

    stop_audio()
    print(
        json.dumps(
            {
                "ok": True,
                "device": str(engine.device),
                "gpu": (
                    torch.cuda.get_device_name(0)
                    if torch.cuda.is_available()
                    else None
                ),
                "torch": torch.__version__,
            },
            ensure_ascii=False,
        )
    )
    return 0


def dump_ssml_preview() -> int:
    samples = [
        ("sayori", "Привет! Я так рада тебя видеть, правда! Пойдём вместе?"),
        ("natsuki", "Эй, я просто решила тебе помочь! Не придумывай лишнего, ясно?"),
        ("yuri", "Если ты не против... я бы хотела немного почитать вместе. Можно?"),
        ("monika", "Добро пожаловать в литературный клуб. Надеюсь, тебе здесь понравится."),
        ("mc", "Ну... ладно. Думаю, я понял. Тогда пойдём вместе!"),
    ]

    for speaker, text in samples:
        profile = _profile_for_line(speaker, text)
        print(f"===== {speaker} =====")
        print(make_ssml(text, profile, speaker=speaker))
        print()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdio", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--dump-ssml", action="store_true")
    parser.add_argument("--no-play", action="store_true")
    args = parser.parse_args()

    if args.stdio:
        return run_stdio()
    if args.dump_ssml:
        return dump_ssml_preview()
    if args.self_test:
        return self_test(play=not args.no_play)

    parser.print_help()
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        log("FATAL top-level error")
        log(traceback.format_exc())
        try:
            FAILED_FLAG.write_text(traceback.format_exc(), encoding="utf-8")
        except Exception:
            pass
        raise
