/**
 * Pure ordering logic for the iOS profile picker (M8): the most recently
 * picked kid should list first with a subtle highlight, instead of always
 * appearing in whatever order the server sent. localStorage read/write
 * (which can throw or be unavailable) stays in main.js — this module only
 * takes the already-read last slug and produces an ordered list.
 */

// `slugs` in the order the server sent them; `lastSlug` the last-picked kid's
// slug (or null/undefined if none remembered, or it's not in the list any
// more). Returns a new array with lastSlug moved to the front when present.
export function orderKidsByLastPicked(slugs, lastSlug) {
  const list = slugs || []
  if (!lastSlug || !list.includes(lastSlug)) return list.slice()
  return [lastSlug, ...list.filter(s => s !== lastSlug)]
}
