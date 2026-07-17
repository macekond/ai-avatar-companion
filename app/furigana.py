"""Japanese furigana annotation for learner-friendly display.

Wraps kanji morphemes in HTML ``<ruby>`` tags with hiragana readings so a
beginner can still read every word without losing the kanji:

  >>> annotate("私は日本語を話します")
  '<ruby>私<rt>わたし</rt></ruby>は<ruby>日本語<rt>にほんご</rt></ruby>を<ruby>話<rt>はな</rt></ruby>します'

Used server-side on outgoing Japanese text (avatar reply sentences, transcript
turns) so the UI only has to render the resulting HTML. Kokoro TTS still gets
the plain text — ``<ruby>`` markup is display-only.

Reading extraction uses pyopenjtalk (already installed for Kokoro), whose
morpheme ``read`` field is the grammatical kanji reading in katakana (私→ワタシ,
not the phonological ワタクシ). Falls back to plain text if pyopenjtalk isn't
importable — Japanese still works, it just displays without furigana.
"""
from __future__ import annotations

import re

# Kanji covers CJK Unified Ideographs (main block) + a few extended blocks that
# appear in modern Japanese. Only the main block matters in practice; the
# extensions are cheap insurance.
_KANJI_RE = re.compile(
    r"[一-鿿"      # CJK Unified Ideographs
    r"㐀-䶿"       # CJK Extension A
    r"豈-﫿]"      # CJK Compatibility Ideographs
)


def contains_kanji(s: str) -> bool:
    return bool(_KANJI_RE.search(s))


def katakana_to_hiragana(s: str) -> str:
    """Shift full-width katakana to hiragana (leaves everything else alone).

    Furigana is conventionally hiragana; readers of Japanese materials for
    children see it as the "easy" script. The OpenJTalk ``read`` field is
    katakana, so we shift it. The shift is a plain codepoint offset within
    the U+30A1..U+30F6 range (ァ..ヶ ↔ ぁ..ゖ).
    """
    out: list[str] = []
    for ch in s:
        c = ord(ch)
        if 0x30A1 <= c <= 0x30F6:
            out.append(chr(c - 0x60))
        else:
            out.append(ch)
    return "".join(out)


def _escape(s: str) -> str:
    """Minimal HTML escape — we only emit our own <ruby>/<rt> tags."""
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def annotate(text: str) -> str:
    """Return *text* with kanji morphemes wrapped in ``<ruby>…<rt>…</rt></ruby>``.

    Non-kanji tokens (hiragana, katakana, punctuation, ASCII) are HTML-escaped
    and emitted as-is. Empty input returns empty. If pyopenjtalk isn't
    installed (or the OpenJTalk dict is missing on a fresh install with no
    network), the plain escaped text is returned so the caller still gets
    valid HTML — Japanese display keeps working, just without furigana.
    """
    if not text:
        return ""
    try:
        import pyopenjtalk
        morphemes = pyopenjtalk.run_frontend(text)
    except Exception:
        # Missing package, missing dict, or malformed input — fall back to
        # plain (escaped) text. Never break the reply over furigana.
        return _escape(text)

    parts: list[str] = []
    for m in morphemes:
        surface = m.get("string", "")
        if not surface:
            continue
        if not contains_kanji(surface):
            parts.append(_escape(surface))
            continue
        # Prefer the grammatical reading ('read'); pron carries phonological
        # changes (は→ワ) that are wrong on top of kanji.
        reading_kata = m.get("read", "") or m.get("pron", "")
        if not reading_kata or not contains_kanji(surface):
            parts.append(_escape(surface))
            continue
        reading_hira = katakana_to_hiragana(reading_kata)
        parts.append(
            f"<ruby>{_escape(surface)}<rt>{_escape(reading_hira)}</rt></ruby>"
        )
    return "".join(parts)


def annotate_for(text: str, language: str) -> str | None:
    """Return furigana-annotated HTML for Japanese, otherwise None.

    Convenience for message emitters that don't want to branch on language:
    always call ``annotate_for(text, active_language)`` and attach the result
    as a separate ``html`` field on the outgoing message. The UI picks the
    ``html`` when present, else falls back to plain ``text``.
    """
    if language != "ja" or not text:
        return None
    return annotate(text)
