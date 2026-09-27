import test from 'node:test'
import assert from 'node:assert/strict'
import { iosLabelsFor } from './ios-labels.js'

test('iosLabelsFor returns English labels for en', () => {
  const labels = iosLabelsFor('en')
  assert.equal(labels.start, '👋 Say hi to Nova!')
  assert.equal(labels.ptt, '🎤 Hold to talk')
  assert.equal(labels.replay, '🔊 Say it again')
  assert.equal(labels.state.listening, '🎤 Listening…')
})

test('iosLabelsFor returns Japanese labels for ja', () => {
  const labels = iosLabelsFor('ja')
  assert.equal(labels.start, '👋 ノヴァにあいさつ！')
  assert.equal(labels.ptt, '🎤 おしてはなしてね')
  assert.equal(labels.replay, '🔊 もういちど')
  assert.equal(labels.state.thinking, '💭 えーと…')
  assert.equal(labels.state.didnt_catch, 'もういちど いってね')
})

test('iosLabelsFor falls back to English for an unknown or missing language', () => {
  assert.equal(iosLabelsFor('fr').start, '👋 Say hi to Nova!')
  assert.equal(iosLabelsFor(undefined).start, '👋 Say hi to Nova!')
})
