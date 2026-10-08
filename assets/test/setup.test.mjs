import { test } from 'node:test'
import assert from 'node:assert/strict'
import { initializeSetup } from '../js/setup.js'

function page(hash) {
  let focused = false
  let changed
  let cleanURL
  const input = { value: '', focus() { focused = true } }
  const email = { focus() { focused = true } }
  const elements = {
    'setup-form': { querySelector: selector => selector.includes('[code]') ? input : email },
    'setup-manual-code': { hidden: false },
    'setup-link-received': { hidden: true },
    'setup-change-code': { addEventListener: (_, callback) => { changed = callback } },
  }
  initializeSetup(
    { getElementById: id => elements[id] },
    { hash, pathname: '/setup', search: '' },
    { state: null, replaceState: (_, __, url) => { cleanURL = url } },
  )
  return { input, elements, get focused() { return focused }, change: () => changed(), get cleanURL() { return cleanURL } }
}

test('setup link fills the code, cleans the URL and focuses email', () => {
  const code = 'a'.repeat(48)
  const p = page('#code=' + code)
  assert.equal(p.input.value, code)
  assert.equal(p.cleanURL, '/setup')
  assert.equal(p.elements['setup-manual-code'].hidden, true)
  assert.equal(p.elements['setup-link-received'].hidden, false)
  assert.equal(p.focused, true)
  p.change()
  assert.equal(p.elements['setup-manual-code'].hidden, false)
})

test('invalid setup links are removed but leave manual entry visible', () => {
  const p = page('#code=invalid')
  assert.equal(p.input.value, '')
  assert.equal(p.cleanURL, '/setup')
  assert.equal(p.elements['setup-manual-code'].hidden, false)
})

test('normal URLs keep the original form intact', () => {
  const p = page('')
  assert.equal(p.cleanURL, undefined)
  assert.equal(p.elements['setup-manual-code'].hidden, false)
})

test('completed setup redirects also discard the old setup fragment', () => {
  let cleaned = false
  initializeSetup({ getElementById: () => null }, { hash: '#code=invalid', pathname: '/login', search: '' }, {
    replaceState(_, __, url) { cleaned = true; assert.equal(url, '/login') },
  })
  assert.equal(cleaned, true)
})

test('unrelated fragments are untouched', () => {
  initializeSetup({ getElementById: () => null }, { hash: '#videos' }, {
    replaceState() { assert.fail('unrelated URL changed') },
  })
})
