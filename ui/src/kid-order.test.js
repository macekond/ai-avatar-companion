import test from 'node:test'
import assert from 'node:assert/strict'
import { orderKidsByLastPicked } from './kid-order.js'

test('moves the last-picked kid to the front', () => {
  assert.deepEqual(orderKidsByLastPicked(['a', 'b', 'c'], 'c'), ['c', 'a', 'b'])
  assert.deepEqual(orderKidsByLastPicked(['a', 'b', 'c'], 'a'), ['a', 'b', 'c'])
})

test('returns the original order when no last slug is remembered', () => {
  assert.deepEqual(orderKidsByLastPicked(['a', 'b', 'c'], null), ['a', 'b', 'c'])
  assert.deepEqual(orderKidsByLastPicked(['a', 'b', 'c'], undefined), ['a', 'b', 'c'])
})

test('returns the original order when the remembered slug is not in the list', () => {
  assert.deepEqual(orderKidsByLastPicked(['a', 'b', 'c'], 'zzz'), ['a', 'b', 'c'])
})

test('handles a missing kids array', () => {
  assert.deepEqual(orderKidsByLastPicked(undefined, 'a'), [])
})
