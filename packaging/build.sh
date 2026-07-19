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
#   Release build (on `main`, HEAD is tagged v<version>, working tree clean):
#     src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/Nova_<version>_aarch64.dmg
#   Any other build (feature branch, untagged HEAD, or dirty tree):
#     …/Nova_<version>-<UTC-timestamp>_aarch64.dmg
#
# The timestamp suffix keeps successive local builds from overwriting each
# other and makes it unambiguous which snapshot a shared DMG came from. The
# internal version fields (Cargo.toml, tauri.conf.json, ui/package.json) are
# always the clean semver — guarded by tests/test_version_sync.py.
set -euo pipefail
cd "$(dirname "$0")/.."

TRIPLE="aarch64-apple-darwin"

# Temporary diagnostics for the "No space left on device" CI failure — hdiutil
# fails during DMG creation even with the root volume showing tens of GB free,
# so something's consuming space (or writing to a smaller volume) that a bare
# `df -h /` doesn't explain. Report the root volume, $TMPDIR's volume (mktemp
# -d below stages the DMG source there — may be a different, smaller volume
# than '/'), and the size of the biggest build directories at each phase.
_report_disk() {
  echo "---- disk report: $1 ----"
  df -h / "${TMPDIR:-/tmp}"
  du -sh .venv ui/node_modules packaging/build packaging/dist \
       src-tauri/target "${TMPDIR:-/tmp}" 2>/dev/null || true
}

_report_disk "start"

echo "==> [1/3] Building frontend (ui/dist)"
npm --prefix ui run build
_report_disk "after frontend build"

echo "==> [2/3] Freezing Python sidecar (PyInstaller)"
source .venv/bin/activate
pyinstaller --noconfirm --clean packaging/nova-server.spec \
    --distpath packaging/dist --workpath packaging/build
mkdir -p src-tauri/binaries
cp packaging/dist/nova-server "src-tauri/binaries/nova-server-${TRIPLE}"
_report_disk "after PyInstaller freeze"

echo "==> [3/3] Building Tauri app + DMG"
source "$HOME/.cargo/env"
# Run from the repo root — the CLI locates src-tauri/ relative to cwd.
# Bundle only the .app: Tauri's own DMG script drives Finder via
# AppleScript and fails in headless shells; hdiutil below is reliable.
./ui/node_modules/.bin/tauri build --target "${TRIPLE}" --bundles app
_report_disk "after Tauri build"

BUNDLE_DIR="src-tauri/target/${TRIPLE}/release/bundle"
VERSION=$(python3 -c "import json;print(json.load(open('src-tauri/tauri.conf.json'))['version'])")

# Decide the DMG label. A release build is only ever produced from the exact
# commit tagged v<version> with a clean working tree — anything else (untagged
# HEAD, uncommitted changes, or a tag that doesn't match this version) is a
# dev build and gets a UTC timestamp so it's traceable and doesn't collide
# with siblings. Branch name is intentionally not part of the check: CI runs
# `actions/checkout` in detached HEAD, and the tag alone is the authoritative
# release signal.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
TAG_AT_HEAD=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
WORKTREE_DIRTY=$(git status --porcelain 2>/dev/null | head -n1)
if [[ "${TAG_AT_HEAD}" == "v${VERSION}" && -z "${WORKTREE_DIRTY}" ]]; then
  LABEL="${VERSION}"
  echo "==> Release build: Nova_${LABEL}"
else
  LABEL="${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Dev build (branch=${BRANCH}, tag=${TAG_AT_HEAD:-none}, dirty=$([[ -n \"${WORKTREE_DIRTY}\" ]] && echo yes || echo no)): Nova_${LABEL}"
fi
DMG="${BUNDLE_DIR}/dmg/Nova_${LABEL}_aarch64.dmg"

mkdir -p "${BUNDLE_DIR}/dmg"
du -sh "${BUNDLE_DIR}/macos/Nova.app"
STAGING=$(mktemp -d)
echo "STAGING=${STAGING} on volume: $(df -h "${STAGING}" | tail -n1)"
cp -R "${BUNDLE_DIR}/macos/Nova.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
_report_disk "staged, before hdiutil"

# hdiutil's auto-sizing pass (no explicit -size) has been observed to fail
# with a spurious "No space left on device" on GitHub's macOS runners even
# with tens of GB genuinely free — a known interaction between the DMG's
# temporary read-write image and Spotlight indexing the freshly-mounted
# volume mid-build. Pre-computing an explicit -size sidesteps the flaky
# auto-sizing path entirely; -nospotlight stops mdworker from touching the
# temp volume; the retry loop is a defensive net in case it's transient.
SIZE_MB=$(( $(du -sm "${STAGING}" | cut -f1) + 200 ))
for attempt in 1 2 3; do
  if hdiutil create -volname "Nova" -srcfolder "${STAGING}" -ov -format UDZO \
       -size "${SIZE_MB}m" -nospotlight "${DMG}"; then
    break
  fi
  echo "hdiutil attempt ${attempt} failed" >&2
  [[ "${attempt}" == 3 ]] && exit 1
  sleep 5
done
rm -rf "${STAGING}"

APP="${BUNDLE_DIR}/macos/Nova.app"

echo
echo "Done: ${DMG}"
echo
echo "Run the fresh build directly (no install needed):"
echo "    open ${APP}"
echo
echo "Or install: open the DMG, drag Nova to Applications:"
echo "    open ${DMG}"
echo
echo "Note: the app is ad-hoc signed. Recipients installing from a DOWNLOADED"
echo "DMG must right-click → Open the first time (or run:"
echo "xattr -dr com.apple.quarantine Nova.app). A locally-built .app has no"
echo "quarantine attribute — the 'open' command above launches it directly."
