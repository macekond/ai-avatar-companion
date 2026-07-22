#ifndef OpenJTalkBridge_h
#define OpenJTalkBridge_h

#ifdef __cplusplus
extern "C" {
#endif

/// Plain-C bridge to open_jtalk (NativeCores/open_jtalk — cross-compiled
/// successfully for iOS, see ios/spikes/04-tts-kokoro-openjtalk/README.md).
/// Same rationale as LlamaBridge.h: keep open_jtalk's own C types out of
/// Swift's module graph by routing through an opaque handle.
typedef void *NovaOpenJTalkHandle;

/// Loads the mecab dictionary at `dictDir` (the compiled naist-jdic binary
/// directory — not vendored in git, see Phase 9). Returns NULL on failure.
NovaOpenJTalkHandle nova_openjtalk_load(const char *dictDir);

void nova_openjtalk_free(NovaOpenJTalkHandle handle);

/// One extracted morpheme — mirrors pyopenjtalk's `node2feature` dict, only
/// the fields Furigana.swift's `Morpheme` actually needs.
typedef struct {
    const char *surface;   // NJDNode_get_string
    const char *reading;   // NJDNode_get_read (katakana; NULL if empty)
} NovaMorpheme;

/// Runs open_jtalk's text-analysis frontend on `text` — port of
/// pyopenjtalk's `run_frontend`: text2mecab -> Mecab_analysis -> mecab2njd
/// -> njd_set_pronunciation/digit/accent_phrase/accent_type/unvoiced_vowel/
/// long_vowel -> walk the NJD linked list. Invokes `onMorpheme` once per
/// node (strings valid only for the duration of the call). Returns 0 on
/// success.
int nova_openjtalk_analyze(
    NovaOpenJTalkHandle handle,
    const char *text,
    void (*onMorpheme)(NovaMorpheme morpheme, void *context),
    void *context
);

#ifdef __cplusplus
}
#endif

#endif /* OpenJTalkBridge_h */
