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
# misses: ctranslate2 dylibs (faster-whisper), onnxruntime (piper),
# espeak-ng-data + espeakbridge (piper 1.4 bundles them in the package).
for pkg in ("faster_whisper", "ctranslate2", "piper", "onnxruntime"):
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hiddenimports += h

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
