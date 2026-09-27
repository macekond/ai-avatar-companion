/**
 * Plain-language descriptions for the bare CEFR/JLPT level codes shown in
 * the settings level list (M7b) — "Pre A", "N5" etc. mean nothing to a
 * parent unfamiliar with either scale. Shown on iOS only; desktop keeps the
 * bare codes.
 */

const DESCRIPTIONS = {
  'Pre A': 'First words',
  A: 'Beginner',
  B: 'Getting confident',
  C1: 'Advanced',
  C2: 'Near-native',
  N5: 'Beginner',
  N4: 'Elementary',
  N3: 'Intermediate',
  N2: 'Upper-intermediate',
  N1: 'Advanced',
}

// Short plain-language description for a level code, or '' when the code
// isn't one we recognize (never invent a description for an unknown code).
export function levelDescription(code) {
  return DESCRIPTIONS[code] || ''
}
