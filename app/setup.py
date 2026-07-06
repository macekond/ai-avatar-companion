"""Startup environment checks, shared by the CLI and the WebSocket server.

Kept free of terminal formatting so messages can go to a UI as-is.
"""
from __future__ import annotations


def check_ollama(model: str) -> tuple[bool, str]:
    """Return (ok, error_message). Checks Ollama is running and *model* is pulled."""
    try:
        import ollama
        ollama.show(model)
        return True, ""
    except ImportError:
        return False, ("The 'ollama' Python package is not installed. "
                       "Run: pip install ollama")
    except Exception as exc:
        msg = str(exc).lower()
        if "connection" in msg or "connect" in msg or "refused" in msg:
            return False, (
                "Ollama is not running. Open the Ollama app (or run "
                f"'ollama serve'), then make sure the model is pulled: "
                f"ollama pull {model}"
            )
        if "not found" in msg or "404" in msg:
            return False, f"Model '{model}' is not pulled yet. Run: ollama pull {model}"
        return False, f"Ollama error: {exc}"
