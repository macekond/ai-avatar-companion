/**
 * Pure kid-display helpers, shared by the iOS profile picker, the settings
 * kids list, the active-kid pill, and the "Switched to …" toast.
 *
 * `kids` is the optional array the iOS server attaches to `profiles` and
 * `choose_profile` messages: [{slug, name, language}, …]. Desktop never
 * sends it, so every function here falls back to deriving a name from the
 * slug alone (see displayName) when `kids` is absent or a slug isn't in it.
 */

export const LANGUAGE_NAMES = { en: 'English', ja: '日本語' }

// Capitalize slug (underscores → spaces): mia_rose → Mia Rose. This is the
// only display name available for a slug with no matching `kids` entry, and
// the only one at all on desktop (which never sends `kids`).
export function displayName(slug) {
  return slug.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
}

export function findKid(slug, kids) {
  return (kids || []).find(k => k.slug === slug) || null
}

export function languageName(language) {
  return LANGUAGE_NAMES[language] || language || ''
}

// The name to show for `slug`: the real name from `kids` when present
// (Japanese-script names sanitize to unreadable slugs like kid1a2b3c4d, so
// the slug itself is useless for display in that case), else displayName.
export function kidName(slug, kids) {
  const kid = findKid(slug, kids)
  return (kid && kid.name) || displayName(slug)
}

// The kid's practice language, or null when unknown (no `kids` entry).
export function kidLanguage(slug, kids) {
  const kid = findKid(slug, kids)
  return kid ? kid.language : null
}

// "Hana · 日本語" when the kid (and their language) is known, else just the
// display name — used anywhere a kid is shown on iOS (picker, kids list,
// active-kid pill).
export function kidLabel(slug, kids) {
  const kid = findKid(slug, kids)
  if (!kid) return displayName(slug)
  const lang = languageName(kid.language)
  return lang ? `${kid.name} · ${lang}` : kid.name
}
