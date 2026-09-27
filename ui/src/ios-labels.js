/**
 * Kid-facing label tables for the iOS app, keyed by the ACTIVE KID's practice
 * language (known from init/settings/memory_loaded — not the app chrome,
 * which stays English). Desktop never consults this module; the app chrome
 * (settings panel, chips) is intentionally left in English everywhere.
 *
 * Japanese strings are simple hiragana-first phrasing a 7-year-old beginner
 * can read, not literal translations of the English copy.
 */

const EN = {
  start: '👋 Say hi to Nova!',
  ptt: '🎤 Hold to talk',
  replay: '🔊 Say it again',
  state: {
    listening: '🎤 Listening…',
    thinking: '💭 Hmm…',
    didnt_catch: "I didn't hear you — try again?",
  },
}

const JA = {
  start: '👋 ノヴァにあいさつ！',
  ptt: '🎤 おしてはなしてね',
  replay: '🔊 もういちど',
  state: {
    listening: '🎤 きいてるよ…',
    thinking: '💭 えーと…',
    didnt_catch: 'もういちど いってね',
  },
}

export const IOS_KID_LABELS = { en: EN, ja: JA }

export function iosLabelsFor(language) {
  return IOS_KID_LABELS[language] || EN
}
