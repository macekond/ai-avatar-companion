/**
 * Pure hint-text logic for the iOS profile picker's Start button and the kid
 * detail view's "Remove this kid" button (M2) — both are disabled controls
 * that give no clue why, so a short hint is shown alongside them on iOS
 * while disabled.
 */

// Hint under the picker's Start button, given the current form state.
// Empty string means "no hint" (enabled, or nothing typed yet is fine to
// leave unexplained) — callers hide the hint element in that case.
export function startHint(name, language) {
  const hasName = Boolean(name && name.trim())
  if (hasName && language) return ''
  return 'Type a name and pick a language'
}

// Hint under "Remove this kid", given how many kids exist in total.
export function removeKidHint(kidCount) {
  return kidCount <= 1 ? 'Add another kid before removing this one' : ''
}
