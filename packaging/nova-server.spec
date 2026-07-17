# PyInstaller spec for the Nova Python sidecar.
#
# Build (from repo root):
#   pyinstaller --noconfirm --clean packaging/nova-server.spec
#
# Produces dist/nova-server (onefile, arm64). The build script renames it
# to nova-server-aarch64-apple-darwin for Tauri's externalBin convention.
from PyInstaller.utils.hooks import collect_all

datas = [("../config.yaml", ".")]   # seed for ~/.ai-avatar/config.yaml
binaries = []
hiddenimports = []

# Packages with native libs / data files that PyInstaller's static analysis
# misses: ctranslate2 dylibs (faster-whisper), onnxruntime (piper & kokoro),
# espeak-ng-data + espeakbridge (piper 1.4 bundles them in the package),
# and the Japanese g2p chain (misaki → pyopenjtalk + unidic dictionary).
# The unidic dict in particular is a lot of data files that would otherwise
# fail to resolve at runtime inside the frozen bundle.
#
# NOTE (verify at bundle time): the exact unidic package name may be
# `unidic_lite` depending on what misaki[ja] pulls in — check `pip show`
# after `pip install -r requirements.txt` and adjust if needed. Kokoro is
# lazy-loaded (only for Japanese profiles), but its deps must still be
# frozen in for the packaged app to reach the neural path at all.
for pkg in ("faster_whisper", "ctranslate2", "piper", "onnxruntime",
            "kokoro_onnx", "misaki", "pyopenjtalk", "unidic_lite"):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception:
        # Missing optional package (e.g. unidic vs unidic_lite naming) — the
        # runtime falls back to macOS 'say -v Kyoko' for Japanese, so a frozen
        # build still works, just without the neural Kokoro voice.
        pass

hiddenimports += [
    "sounddevice",        # PyInstaller hook bundles libportaudio
    "huggingface_hub",    # lazy import in app/pipeline/tts.py
    "dotenv",
    "yaml",
    "websockets",
    "ollama",
    "httpx",              # ollama client transport
]

a = Analysis(
    ["../app/server.py"],
    pathex=[".."],
    datas=datas,
    binaries=binaries,
    hiddenimports=hiddenimports,
    excludes=["tkinter", "matplotlib", "PIL"],
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    name="nova-server",
    console=True,           # keep stdout: the shell waits for NOVA_READY
    target_arch="arm64",
    codesign_identity=None,
    upx=False,
)
