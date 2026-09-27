import test from 'node:test'
import assert from 'node:assert/strict'
import { startHint, removeKidHint } from './picker-hints.js'

test('startHint is empty once a name and language are both set', () => {
  assert.equal(startHint('Mia', 'en'), '')
  assert.equal(startHint('  Mia  ', 'ja'), '')
})

test('startHint explains what is missing when the form is incomplete', () => {
  assert.equal(startHint('', null), 'Type a name and pick a language')
  assert.equal(startHint('Mia', null), 'Type a name and pick a language')
  assert.equal(startHint('   ', 'en'), 'Type a name and pick a language')
  assert.equal(startHint(null, null), 'Type a name and pick a language')
})

test('removeKidHint explains the disabled remove button for a single kid', () => {
  assert.equal(removeKidHint(1), 'Add another kid before removing this one')
  assert.equal(removeKidHint(0), 'Add another kid before removing this one')
})

test('removeKidHint is empty once there is more than one kid', () => {
  assert.equal(removeKidHint(2), '')
  assert.equal(removeKidHint(5), '')
})
