#!/usr/bin/env bash
# Build the distributable Nova.app + DMG (Apple Silicon).
#
# Prerequisites (one-time):
#   - Xcode command-line tools:  xcode-select --install
#   - Rust toolchain:            curl -sSf https://sh.rustup.rs | sh
#   - Python venv with deps:     python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
#   - UI deps:                   npm --prefix ui install
#
# Usage (from anywhere):
#   packaging/build.sh
#
# Output:
#   src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/Nova_<version>_aarch64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

TRIPLE="aarch64-apple-darwin"

echo "==> [1/3] Building frontend (ui/dist)"
npm --prefix ui run build

echo "==> [2/3] Freezing Python sidecar (PyInstaller)"
source .venv/bin/activate
pyinstaller --noconfirm --clean packaging/nova-server.spec \
    --distpath packaging/dist --workpath packaging/build
mkdir -p src-tauri/binaries
cp packaging/dist/nova-server "src-tauri/binaries/nova-server-${TRIPLE}"

echo "==> [3/3] Building Tauri app + DMG"
source "$HOME/.cargo/env"
# Run from the repo root — the CLI locates src-tauri/ relative to cwd.
./ui/node_modules/.bin/tauri build --target "${TRIPLE}"

DMG=$(ls src-tauri/target/${TRIPLE}/release/bundle/dmg/*.dmg | head -1)
echo
echo "Done: ${DMG}"
echo
echo "Note: the app is ad-hoc signed. Recipients must right-click → Open"
echo "the first time (or run: xattr -dr com.apple.quarantine Nova.app)."
