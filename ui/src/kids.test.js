import test from 'node:test'
import assert from 'node:assert/strict'
import { displayName, findKid, languageName, kidName, kidLanguage, kidLabel } from './kids.js'

test('displayName capitalizes and un-underscores a slug', () => {
  assert.equal(displayName('mia_rose'), 'Mia Rose')
  assert.equal(displayName('tom'), 'Tom')
})

test('findKid returns the matching entry or null', () => {
  const kids = [{ slug: 'zo', name: 'Zoë', language: 'en' }]
  assert.deepEqual(findKid('zo', kids), kids[0])
  assert.equal(findKid('missing', kids), null)
  assert.equal(findKid('zo', undefined), null)
})

test('languageName maps known codes and falls back to the raw code', () => {
  assert.equal(languageName('en'), 'English')
  assert.equal(languageName('ja'), '日本語')
  assert.equal(languageName('fr'), 'fr')
  assert.equal(languageName(undefined), '')
})

test('kidName prefers the real name from kids, falls back to the slug', () => {
  const kids = [{ slug: 'kid1a2b3c4d', name: '花子', language: 'ja' }]
  assert.equal(kidName('kid1a2b3c4d', kids), '花子')
  assert.equal(kidName('mia_rose', kids), 'Mia Rose')
  assert.equal(kidName('mia_rose', undefined), 'Mia Rose')
})

test('kidLanguage returns the kid language or null when unknown', () => {
  const kids = [{ slug: 'zo', name: 'Zoë', language: 'en' }]
  assert.equal(kidLanguage('zo', kids), 'en')
  assert.equal(kidLanguage('missing', kids), null)
  assert.equal(kidLanguage('zo', undefined), null)
})

test('kidLabel combines name and language when both are known', () => {
  const kids = [
    { slug: 'kid1a2b3c4d', name: 'Hana', language: 'ja' },
    { slug: 'tom', name: 'Tom', language: 'en' },
  ]
  assert.equal(kidLabel('kid1a2b3c4d', kids), 'Hana · 日本語')
  assert.equal(kidLabel('tom', kids), 'Tom · English')
})

test('kidLabel falls back to displayName when the kid is unknown', () => {
  assert.equal(kidLabel('mia_rose', undefined), 'Mia Rose')
  assert.equal(kidLabel('mia_rose', []), 'Mia Rose')
})
