"""Durable, content-free diagnostics logging.

Attaches a rotating plain-text `nova.log` handler to the root logger so the
server's own log survives in the packaged app, where stderr goes nowhere. See
docs/superpowers/specs/2026-07-16-durable-diagnostics-logging-design.md.

Convention: stdlib logging + standard levels; machine-relevant diagnostic events
use logfmt `event key=value`; never log child speech / transcript text here.
"""
from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

_LOG_FILENAME = "nova.log"
_MAX_BYTES = 1_000_000
_BACKUP_COUNT = 3
_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"


def configure_logging(log_dir: str | Path) -> None:
    """Attach a rotating nova.log handler to the root logger (idempotent).

    Persists every existing log record beside the telemetry files, so a field
    bug is diagnosable from what a parent sends back. Quiets httpx (one INFO
    line per Ollama call). Safe to call more than once — a second call does not
    stack another nova.log handler.
    """
    directory = Path(log_dir).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    path = (directory / _LOG_FILENAME).resolve()

    root = logging.getLogger()
    # The file handler is set to INFO, but the root logger gates records first;
    # its default is WARNING. Admit INFO so diagnostics land even if this runs
    # before (or without) logging.basicConfig(level=INFO).
    if root.level == logging.NOTSET or root.level > logging.INFO:
        root.setLevel(logging.INFO)
    for h in root.handlers:
        if (isinstance(h, RotatingFileHandler)
                and Path(h.baseFilename).resolve() == path):
            return   # already configured — don't stack a second handler

    handler = RotatingFileHandler(
        path, maxBytes=_MAX_BYTES, backupCount=_BACKUP_COUNT, encoding="utf-8")
    handler.setFormatter(logging.Formatter(_FORMAT))
    handler.setLevel(logging.INFO)
    root.addHandler(handler)

    # One INFO "HTTP Request: …" per Ollama call would drown the file.
    logging.getLogger("httpx").setLevel(logging.WARNING)


def logfmt_str(value) -> str:
    """Quote a value for a logfmt field: bare token when safe, else quoted."""
    s = "" if value is None else str(value)
    if s == "" or any(c in s for c in ' "='):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s
