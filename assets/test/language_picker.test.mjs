import { test } from 'node:test'
import assert from 'node:assert/strict'
import { matchingLanguages } from '../js/hooks/language_picker.js'

const languages = [
  { code: 'nl', label: 'Dutch', terms: ['nl', 'Dutch', 'Nederlands'] },
  { code: 'fr', label: 'French', terms: ['fr', 'French', 'Français'] },
  { code: 'ja', label: 'Japanese', terms: ['ja', 'Japanese', 'Japans', '日本語'] },
]

test('empty search shows preferred languages and the current selection once', () => {
  const codes = selected => matchingLanguages(languages, ['nl', 'fr'], selected, '').map(item => item.code)
  assert.deepEqual(codes(''), ['nl', 'fr'])
  assert.deepEqual(codes('ja'), ['ja', 'nl', 'fr'])
  assert.deepEqual(codes('nl'), ['nl', 'fr'])
})

test('search includes the full list and matches names, codes and accents', () => {
  for (const [query, code] of [['Japans', 'ja'], ['日本語', 'ja'], ['FRANCAIS', 'fr'], [' nl ', 'nl']]) {
    assert.equal(matchingLanguages(languages, ['nl'], '', query)[0].code, code)
  }
  assert.deepEqual(matchingLanguages(languages, ['nl'], '', 'zzz'), [])
})
