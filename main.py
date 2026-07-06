#!/usr/bin/env python3
"""Phase 1 prototype — text-only chat with Nova.

No TTS, no avatar, no mic yet. The sentence-streaming pipeline is already
wired so the same LLMPipeline interface slots into Phase 2 unchanged.

Usage:
    python main.py
    python main.py --config path/to/config.yaml

In-session commands:
    clear   — wipe conversation history and start fresh
    quit    — exit (also: exit, q, Ctrl-C, Ctrl-D)
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Load .env before any other imports so API keys are available
from dotenv import load_dotenv
load_dotenv()

from app.config import Config
from app.pipeline.llm import LLMPipeline

# ---------------------------------------------------------------------------
# Terminal colour helpers (disabled when output is not a tty or NO_COLOR set)
# ---------------------------------------------------------------------------
_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ

def _c(code: str) -> str:
    return f"\033[{code}m" if _COLOR else ""

RESET  = _c("0")
BOLD   = _c("1")
DIM    = _c("2")
CYAN   = _c("96")
GREEN  = _c("92")
YELLOW = _c("93")
RED    = _c("91")


# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------

# Shared with app/server.py — plain-text messages, suitable for the UI too.
from app.setup import check_ollama


# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

def print_banner(avatar_name: str, child_name: str, model: str) -> None:
    w = 54
    print(f"\n{BOLD}{CYAN}{'─' * w}{RESET}")
    print(f"  {BOLD}✨  {avatar_name} — English Practice Companion{RESET}")
    print(f"  {DIM}Talking with: {child_name}   model: {model}{RESET}")
    print(f"  {DIM}Commands: {BOLD}clear{RESET}{DIM} · {BOLD}quit{RESET}")
    print(f"{BOLD}{CYAN}{'─' * w}{RESET}\n")


def nova_print(avatar_name: str, sentences: list[str]) -> None:
    """Print a full response (list of sentences) as Nova."""
    text = " ".join(sentences)
    print(f"{GREEN}{BOLD}{avatar_name}:{RESET} {GREEN}{text}{RESET}\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Nova — AI English companion")
    p.add_argument("--config", default="config.yaml", help="Path to config.yaml")
    p.add_argument("--voice", action="store_true",
                   help="Phase 2 voice mode: push-to-talk STT + Piper TTS")
    p.add_argument("--profile",
                   help="Profile slug to load (overrides config.yaml child.name)")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    # --- Load config ---
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"{RED}Error:{RESET} config file not found: {config_path}", file=sys.stderr)
        sys.exit(1)

    config = Config.load(str(config_path))
    avatar_name = config.personality.avatar_name
    child_name = config.child.name
    model = config.models.llm.model

    # --- Check Ollama ---
    print(f"{DIM}Checking Ollama ({model})…{RESET}", end="", flush=True)
    ok, err = check_ollama(model)
    if not ok:
        print(f"\r{YELLOW}⚠  {err}{RESET}\n")
        sys.exit(1)
    print(f"\r{DIM}✓ Ollama ready ({model}){RESET}           ")

    pipeline = LLMPipeline(config)

    # --- Route to the appropriate mode ---
    if args.voice:
        voice_loop(config, pipeline)
        return

    # --- Text mode (Phase 1) ---
    print_banner(avatar_name, child_name, model)

    # Opening line from Nova (hardcoded — no LLM call needed for a greeting)
    print(
        f"{GREEN}{BOLD}{avatar_name}:{RESET} "
        f"{GREEN}Hi {child_name}! I'm {avatar_name}, your English practice friend. "
        f"What did you do today?{RESET}\n"
    )

    # --- Chat loop ---
    while True:
        try:
            raw = input(f"{YELLOW}{BOLD}You:{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            print(f"\n{DIM}Goodbye!{RESET}")
            break

        if not raw:
            continue

        if raw.lower() in {"quit", "exit", "q"}:
            print(f"{DIM}Goodbye!{RESET}")
            break

        if raw.lower() == "clear":
            pipeline.clear_history()
            print(f"{DIM}Conversation cleared.{RESET}\n")
            continue

        # Stream sentences from the LLM, printing each as it arrives
        print(f"{GREEN}{BOLD}{avatar_name}:{RESET} ", end="", flush=True)
        collected: list[str] = []
        try:
            for sentence in pipeline.chat(raw):
                collected.append(sentence)
                # Print each sentence as it streams in (this is where TTS hooks in Phase 2)
                print(f"{GREEN}{sentence}{RESET} ", end="", flush=True)
        except RuntimeError as exc:
            err = str(exc).lower()
            if "connection" in err or "connect" in err or "refused" in err:
                print(
                    f"\n{YELLOW}[Nova's brain is napping — "
                    f"is Ollama still running? Try: ollama serve]{RESET}"
                )
            else:
                print(f"\n{YELLOW}[Something went wrong: {exc}]{RESET}")

        print("\n")  # newline after the full streamed response


# ---------------------------------------------------------------------------
# Phase 2 — voice loop
# ---------------------------------------------------------------------------

def voice_loop(config: Config, pipeline: LLMPipeline) -> None:
    """Phase 2: push-to-talk → STT → LLM (streamed) → TTS → repeat.

    Each sentence from the LLM is spoken as soon as it is ready —
    the child hears the first sentence while the rest is still generating.
    This is the same timing advantage as the text mode, now heard aloud.
    """
    from app.pipeline.stt import STTPipeline
    from app.pipeline.tts import TTSPipeline

    avatar_name = config.personality.avatar_name
    child_name = config.child.name

    # Models load/download on first use — do this before greeting
    print(f"{DIM}Initialising speech models…{RESET}")
    try:
        stt = STTPipeline(config)
    except RuntimeError as exc:
        print(f"{RED}STT error:{RESET} {exc}", file=sys.stderr)
        sys.exit(1)
    tts = TTSPipeline(config)

    print_banner(avatar_name, child_name, config.models.llm.model)

    # Opening greeting — spoken aloud
    greeting = (
        f"Hi {child_name}! I'm {avatar_name}, your English practice friend. "
        f"What did you do today?"
    )
    print(f"{GREEN}{BOLD}{avatar_name}:{RESET} {GREEN}{greeting}{RESET}\n")
    tts.speak(greeting)

    while True:
        print(f"{DIM}Press {BOLD}SPACE{RESET}{DIM} to start talking, press {BOLD}SPACE{RESET}{DIM} again to send…{RESET}")
        try:
            audio = stt.record()
        except RuntimeError as exc:
            print(f"{RED}Recording error:{RESET} {exc}", file=sys.stderr)
            sys.exit(1)
        except KeyboardInterrupt:
            print(f"\n{DIM}Goodbye!{RESET}")
            break

        if len(audio) == 0:
            continue

        print(f"{DIM}Transcribing…{RESET}", end="\r", flush=True)
        transcript = stt.transcribe(audio)

        if not transcript:
            msg = "I didn't hear you — try again!"
            print(f"{YELLOW}[Didn't catch that]{RESET}\n")
            tts.speak(msg)
            continue

        # Show what the app heard (design §2.5: visible transcript helps learner)
        print(f"{YELLOW}{BOLD}You:{RESET} {YELLOW}{transcript}{RESET}\n")

        # LLM → TTS: speak each sentence as it arrives from the stream
        print(f"{GREEN}{BOLD}{avatar_name}:{RESET} ", end="", flush=True)
        try:
            for sentence in pipeline.chat(transcript):
                print(f"{GREEN}{sentence}{RESET} ", end="", flush=True)
                tts.speak(sentence)
        except RuntimeError as exc:
            err = str(exc).lower()
            if "connection" in err or "refused" in err:
                msg = "My brain is napping — is Ollama still running?"
                print(f"\n{YELLOW}[{msg}]{RESET}")
                tts.speak(msg)
            else:
                print(f"\n{YELLOW}[Error: {exc}]{RESET}")
        print("\n")


if __name__ == "__main__":
    main()
