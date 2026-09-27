import test from 'node:test'
import assert from 'node:assert/strict'
import { levelDescription } from './level-descriptions.js'

test('levelDescription maps CEFR codes to plain language', () => {
  assert.equal(levelDescription('Pre A'), 'First words')
  assert.equal(levelDescription('A'), 'Beginner')
  assert.equal(levelDescription('B'), 'Getting confident')
  assert.equal(levelDescription('C1'), 'Advanced')
  assert.equal(levelDescription('C2'), 'Near-native')
})

test('levelDescription maps JLPT codes to plain language', () => {
  assert.equal(levelDescription('N5'), 'Beginner')
  assert.equal(levelDescription('N4'), 'Elementary')
  assert.equal(levelDescription('N3'), 'Intermediate')
  assert.equal(levelDescription('N2'), 'Upper-intermediate')
  assert.equal(levelDescription('N1'), 'Advanced')
})

test('levelDescription returns empty string for an unknown code', () => {
  assert.equal(levelDescription('Z9'), '')
  assert.equal(levelDescription(''), '')
  assert.equal(levelDescription(undefined), '')
})
