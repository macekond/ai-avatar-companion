.PHONY: bundle test dev deps clean distclean

# Build the distributable Nova.app + DMG (see packaging/build.sh)
bundle:
	packaging/build.sh

test:
	.venv/bin/python -m pytest -q

dev:
	.venv/bin/python run.py

# Install everything needed for `make dev`, `make test`, and `make bundle`
# into .venv. Run after `python3 -m venv .venv` on a fresh clone. Deliberately
# NOT a prereq of bundle/test/dev — no one wants to reinstall on every build.
deps:
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements-dev.txt

# Remove build artefacts + accumulated dev-timestamped DMGs (~1.5 GB on a
# typical dev machine). Keeps the Rust compilation cache under
# src-tauri/target/ (2 GB, but multi-minute rebuild) — use distclean for that.
clean:
	rm -rf packaging/build packaging/dist
	rm -rf src-tauri/binaries
	rm -rf ui/dist
	rm -rf src-tauri/target/*/release/bundle/macos/Nova.app
	find src-tauri/target -type f -name "*.dmg" -delete 2>/dev/null || true
	find . -type d -name __pycache__ -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -not -path "./.venv/*" -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaned build artefacts. Rust cache kept — use 'make distclean' to remove it too."

# Also nuke the Rust compilation cache (~2 GB). Next `make bundle` will
# recompile all Tauri/crate deps from scratch (~5-10 min).
distclean: clean
	rm -rf src-tauri/target
	@echo "Cleaned everything including Rust cache."
