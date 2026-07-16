"""Durable diagnostics logging setup."""
from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

import pytest

from app.logging_setup import configure_logging, logfmt_str


@pytest.fixture
def _clean_root():
    """Remove any nova.log handler this test adds, so tests don't leak handles."""
    root = logging.getLogger()
    before = list(root.handlers)
    root_level = root.level
    httpx_level = logging.getLogger("httpx").level
    yield
    for h in list(root.handlers):
        if h not in before:
            root.removeHandler(h)
            h.close()
    root.setLevel(root_level)
    logging.getLogger("httpx").setLevel(httpx_level)


class TestConfigureLogging:
    def test_writes_records_to_nova_log(self, tmp_path, _clean_root):
        configure_logging(tmp_path)
        logging.getLogger("nova.test").info("hello-marker")
        for h in logging.getLogger().handlers:
            h.flush()
        assert "hello-marker" in (tmp_path / "nova.log").read_text()

    def test_creates_missing_dir(self, tmp_path, _clean_root):
        target = tmp_path / "logs"
        configure_logging(target)
        assert target.is_dir()

    def test_idempotent_no_duplicate_handler(self, tmp_path, _clean_root):
        configure_logging(tmp_path)
        configure_logging(tmp_path)
        nova = [h for h in logging.getLogger().handlers
                if isinstance(h, RotatingFileHandler)
                and Path(h.baseFilename).name == "nova.log"]
        assert len(nova) == 1

    def test_quiets_httpx(self, tmp_path, _clean_root):
        configure_logging(tmp_path)
        assert logging.getLogger("httpx").level >= logging.WARNING


class TestLogfmtStr:
    def test_plain_token_unquoted(self):
        assert logfmt_str("noreason") == "noreason"

    def test_spaces_quoted(self):
        assert logfmt_str("going away") == '"going away"'

    def test_empty_quoted(self):
        assert logfmt_str("") == '""'

    def test_none_quoted(self):
        assert logfmt_str(None) == '""'

    def test_embedded_quote_escaped(self):
        assert logfmt_str('a"b') == '"a\\"b"'

    def test_newline_is_quoted_and_escaped(self):
        # A control char must never pass through bare — a client-controlled close
        # reason with a newline would otherwise inject a second log line.
        result = logfmt_str("x\ninjected")
        assert "\n" not in result
        assert result == '"x\\ninjected"'

    def test_tab_is_quoted_and_escaped(self):
        assert logfmt_str("a\tb") == '"a\\tb"'
