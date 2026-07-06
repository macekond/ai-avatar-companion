.PHONY: bundle test dev

# Build the distributable Nova.app + DMG (see packaging/build.sh)
bundle:
	packaging/build.sh

test:
	.venv/bin/python -m pytest -q

dev:
	.venv/bin/python run.py
