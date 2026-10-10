import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const source = readFileSync(new URL('../js/app.js', import.meta.url), 'utf8')
const hookSource = source.slice(
  source.indexOf('const ThumbnailPreviewHook = {'),
  source.indexOf('const AutoOpenFilePickerHook = {'),
)
const hook = vm.runInNewContext(`${hookSource}; ThumbnailPreviewHook`, {
  URL,
  document: { baseURI: 'https://dashboard.example/' },
  window: { addEventListener() {} },
})
const playlist = 'https://media.example/playlist.m3u8?token=example'
const original = 'https://media.example/original?signature=example'

test('signed playlists use the original when native HLS is unavailable', () => {
  for (const supported of [false, true]) {
    const context = { video: { canPlayType: () => supported ? 'maybe' : '' } }
    assert.equal(hook.selectPlayableSource.call(context, playlist, original), supported ? playlist : original)
    assert.equal(hook.selectPlayableSource.call(context, original, ''), original)
  }
})

test('failed native HLS falls back once and stays on the original during updates', () => {
  let onError
  let loads = 0
  const context = {
    ...hook,
    el: { dataset: { previewSrc: playlist, fallbackSrc: original } },
    video: {
      canPlayType: () => 'maybe',
      addEventListener(event, handler) { if (event === 'error') onError = handler },
      load() { loads++ },
    },
    scrubArea: { addEventListener() {} },
    videoContainer: {},
  }
  context.bindEvents()
  context.loadVideoSource()
  assert.equal(context.video.src, playlist)
  onError()
  assert.equal(context.video.src, original)
  context.loadVideoSource()
  onError()
  assert.equal(loads, 2)
})
