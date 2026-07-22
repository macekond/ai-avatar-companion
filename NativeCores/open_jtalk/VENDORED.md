# Vendored open_jtalk source

Extracted from `pyopenjtalk` 0.4.1's sdist (`pip download --no-binary=:all: pyopenjtalk`,
then `lib/open_jtalk/src/`), which vendors open_jtalk 1.11 itself. Not a git submodule
(the sdist isn't a git repo) — plain vendored source, same rationale as any other
third-party code carried in-tree.

License: BSD-style, Copyright (c) 2008-2016 Nagoya Institute of Technology — see `COPYING`.
Compatible with this project's redistribution-for-a-fee requirement (see root `CLAUDE.md`).

This is the C++ library only (mecab/njd/jpcommon text-analysis pipeline) — the dictionary
data (`open_jtalk_dic_utf_8-1.11`, ~50-100MB of `.dic`/`.bin` files) is a separate download,
not vendored here; it belongs with the rest of Phase 9's on-demand model assets, not in git.

See `ios/spikes/04-tts-kokoro-openjtalk/README.md` for cross-compile results and status.
