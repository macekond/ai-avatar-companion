#!/usr/bin/env python3
"""Launch script for Phase 3 UI.

Starts the Python WebSocket server and the Vite frontend dev server,
waits for both to be ready, then opens the browser.

    python run.py

Keep the CLI available for testing:
    python main.py            # text mode
    python main.py --voice    # voice mode (no browser)
"""
import os
import signal
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

ROOT   = Path(__file__).parent
UI_DIR = ROOT / "ui"
PYTHON = str(Path(sys.executable))

FRONTEND_URL = "http://localhost:5173"
WS_PORT      = 8765


def ensure_npm_deps() -> None:
    if not (UI_DIR / "node_modules").exists():
        print("Installing frontend dependencies (first run)…")
        subprocess.run(["npm", "install"], cwd=UI_DIR, check=True)


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Nova UI launcher")
    parser.add_argument("--profile",
                        help="Profile slug to load (overrides config.yaml child.name)")
    args = parser.parse_args()

    ensure_npm_deps()

    procs: list[subprocess.Popen] = []

    def shutdown(sig=None, frame=None):
        print("\nShutting down…")
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        sys.exit(0)

    signal.signal(signal.SIGINT,  shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    server_cmd = [PYTHON, "-m", "app.server"]
    if args.profile:
        server_cmd += ["--profile", args.profile]

    print("Starting Python pipeline server…")
    ws_proc = subprocess.Popen(server_cmd, cwd=ROOT)
    procs.append(ws_proc)

    print("Starting Vite frontend server…")
    vite_proc = subprocess.Popen(
        ["npm", "run", "dev"],
        cwd=UI_DIR,
    )
    procs.append(vite_proc)

    # Give servers a moment to bind their ports
    print(f"Waiting for servers… (WebSocket :{WS_PORT}, Vite :5173)")
    time.sleep(3)

    print(f"Opening {FRONTEND_URL}")
    webbrowser.open(FRONTEND_URL)

    print("Running. Press Ctrl-C to stop.")
    try:
        ws_proc.wait()
    except KeyboardInterrupt:
        shutdown()


if __name__ == "__main__":
    main()
