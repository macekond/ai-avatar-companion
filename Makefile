.PHONY: bundle test dev deps

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
