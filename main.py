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

def check_ollama(model: str) -> tuple[bool, str]:
    """Return (ok, error_message). Checks that Ollama is running and the model is pulled."""
    try:
        import ollama
        ollama.show(model)
        return True, ""
    except ImportError:
        return False, "The 'ollama' Python package is not installed. Run: pip install ollama"
    except Exception as exc:
        msg = str(exc).lower()
        if "connection" in msg or "connect" in msg or "refused" in msg:
            return False, (
                f"Ollama is not running.\n"
                f"  Start it with: {BOLD}ollama serve{RESET}\n"
                f"  Then ensure the model is pulled: {BOLD}ollama pull {model}{RESET}"
            )
        if "not found" in msg or "404" in msg:
            return False, (
                f"Model '{model}' is not pulled yet.\n"
                f"  Run: {BOLD}ollama pull {model}{RESET}"
            )
        return False, f"Ollama error: {exc}"


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
    p = argparse.ArgumentParser(description="Nova — Phase 1 text prototype")
    p.add_argument("--config", default="config.yaml", help="Path to config.yaml")
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

    # --- Banner ---
    print_banner(avatar_name, child_name, model)
    pipeline = LLMPipeline(config)

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


if __name__ == "__main__":
    main()
