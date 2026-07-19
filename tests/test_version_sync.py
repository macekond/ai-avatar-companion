"""The app's version lives in four files that must agree at release time:

  * src-tauri/Cargo.toml       — Rust crate metadata (Tauri wrapper)
  * src-tauri/tauri.conf.json  — Tauri bundle identifier & installer version
  * ui/package.json            — Vite/npm package metadata
  * ui/package-lock.json       — npm's own embedded copy of that version

Nothing forces them in sync at build time — a version bump that touches only
one file ships a schizophrenic release (mismatched App info panel vs. installer
metadata). This test pins the invariant so the divergence is caught at
`make test`, not at the release itself.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent


def _cargo_version() -> str:
    text = (REPO_ROOT / "src-tauri" / "Cargo.toml").read_text(encoding="utf-8")
    # First `version = "..."` line at package scope. Anchored to line start so
    # a dependency's `version = "1.2"` deeper in the file can't win the match.
    m = re.search(r'^version\s*=\s*"([^"]+)"', text, flags=re.MULTILINE)
    assert m, "src-tauri/Cargo.toml: no top-level version line found"
    return m.group(1)


def _tauri_conf_version() -> str:
    data = json.loads((REPO_ROOT / "src-tauri" / "tauri.conf.json").read_text(encoding="utf-8"))
    return data["version"]


def _ui_package_version() -> str:
    data = json.loads((REPO_ROOT / "ui" / "package.json").read_text(encoding="utf-8"))
    return data["version"]


def _ui_lockfile_version() -> str:
    # npm embeds the package's own version twice in package-lock.json (top
    # level and under packages[""]). A bump that touches package.json but not
    # the lockfile goes unnoticed by `npm ci` until it's run — but `npm ci`
    # (unlike `install`) refuses to silently rewrite the file, so a stale
    # lockfile fails release CI instead. Catch the drift here at `make test`.
    data = json.loads((REPO_ROOT / "ui" / "package-lock.json").read_text(encoding="utf-8"))
    return data["version"]


class TestVersionSync:
    def test_all_three_versions_agree(self):
        versions = {
            "src-tauri/Cargo.toml": _cargo_version(),
            "src-tauri/tauri.conf.json": _tauri_conf_version(),
            "ui/package.json": _ui_package_version(),
            "ui/package-lock.json": _ui_lockfile_version(),
        }
        unique = set(versions.values())
        assert len(unique) == 1, (
            "Version drift across release files — bump them together:\n  "
            + "\n  ".join(f"{p}: {v}" for p, v in versions.items())
        )

    def test_version_is_semver(self):
        # Match the shape Tauri's installer expects (MAJOR.MINOR.PATCH, no
        # leading v, no pre-release suffix — the Tauri bundler rejects those).
        assert re.fullmatch(r"\d+\.\d+\.\d+", _cargo_version()), _cargo_version()
