#import "OpenJTalkBridge.h"

// Bare-filename includes match open_jtalk's own source convention (see
// NativeCores/open_jtalk/mecab2njd/mecab2njd.c) — header search paths for
// each subdirectory are set in project.yml, mirroring the CMakeLists.txt
// include_directories() list this library was proven to build with.
#include "mecab.h"
#include "njd.h"
#include "mecab2njd.h"
#include "text2mecab.h"
#include "njd_set_pronunciation.h"
#include "njd_set_digit.h"
#include "njd_set_accent_phrase.h"
#include "njd_set_accent_type.h"
#include "njd_set_unvoiced_vowel.h"
#include "njd_set_long_vowel.h"

#include <string>

namespace {
struct NovaOpenJTalkEngine {
    Mecab mecab;
};
}

NovaOpenJTalkHandle nova_openjtalk_load(const char *dictDir) {
    auto *engine = new NovaOpenJTalkEngine();
    if (!Mecab_initialize(&engine->mecab)) {
        delete engine;
        return nullptr;
    }
    if (!Mecab_load(&engine->mecab, dictDir)) {
        Mecab_clear(&engine->mecab);
        delete engine;
        return nullptr;
    }
    return engine;
}

void nova_openjtalk_free(NovaOpenJTalkHandle handle) {
    if (!handle) return;
    auto *engine = static_cast<NovaOpenJTalkEngine *>(handle);
    Mecab_clear(&engine->mecab);
    delete engine;
}

// Port of pyopenjtalk's run_frontend (openjtalk.pyx): text2mecab ->
// Mecab_analysis -> mecab2njd -> the same fixed njd_set_* sequence -> walk
// the NJD linked list emitting one callback per node.
int nova_openjtalk_analyze(
    NovaOpenJTalkHandle handle,
    const char *text,
    void (*onMorpheme)(NovaMorpheme morpheme, void *context),
    void *context
) {
    if (!handle) return -1;
    auto *engine = static_cast<NovaOpenJTalkEngine *>(handle);

    char buff[8192];
    text2mecab(buff, text);
    if (!Mecab_analysis(&engine->mecab, buff)) return -2;

    NJD njd;
    NJD_initialize(&njd);
    mecab2njd(&njd, Mecab_get_feature(&engine->mecab), Mecab_get_size(&engine->mecab));
    njd_set_pronunciation(&njd);
    njd_set_digit(&njd);
    njd_set_accent_phrase(&njd);
    njd_set_accent_type(&njd);
    njd_set_unvoiced_vowel(&njd);
    njd_set_long_vowel(&njd);

    for (NJDNode *node = njd.head; node != nullptr; node = node->next) {
        NovaMorpheme morpheme;
        morpheme.surface = NJDNode_get_string(node);
        const char *reading = NJDNode_get_read(node);
        morpheme.reading = (reading && reading[0] != '\0') ? reading : nullptr;
        onMorpheme(morpheme, context);
    }

    NJD_refresh(&njd);
    NJD_clear(&njd);
    Mecab_refresh(&engine->mecab);
    return 0;
}
