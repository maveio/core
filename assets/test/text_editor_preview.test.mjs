import { test } from 'node:test'
import assert from 'node:assert/strict'
import { previewSource, previewTime, TextEditorPreviewHook } from '../js/hooks/text_editor_preview.js'

globalThis.document = { baseURI: 'https://dashboard.example/' }
globalThis.window = { innerWidth: 800, innerHeight: 600 }

test('signed HLS previews use native playback or the existing original fallback', () => {
  const hls = 'https://media.example/playlist.m3u8?token=example'
  const original = 'https://media.example/original?token=example'
  assert.equal(previewSource({ canPlayType: () => 'maybe' }, hls, original), hls)
  assert.equal(previewSource({ canPlayType: () => '' }, hls, original), original)
  assert.equal(previewSource({}, original, ''), original)
})

test('preview seeks are bounded by the available video duration', () => {
  assert.equal(previewTime(-1, 20), 0)
  assert.equal(previewTime(8.125, 20), 8.125)
  assert.equal(previewTime(30, 20), 19.999)
  assert.equal(previewTime(8, NaN), 8)
})

test('hover preview loads once, seeks on subsequent passages and never plays', () => {
  let loads = 0
  const context = {
    ...TextEditorPreviewHook,
    el: { dataset: { previewSrc: '/original', fallbackSrc: '/original' } },
    preview: {
      hidden: true, id: 'frame', style: {}, offsetWidth: 240, offsetHeight: 170,
      querySelector: () => ({}),
    },
    video: {
      readyState: 2, duration: 100, seeking: false,
      classList: { add() {}, remove() {} },
      load() { loads++ },
      play() { assert.fail('frame previews must never play') },
    },
    status: {},
  }
  const target = seconds => ({
    isConnected: true, dataset: { previewTime: String(seconds) }, textContent: '00:08 – 00:10',
    setAttribute() {},
    getBoundingClientRect: () => ({ right: 700, left: 600, top: 590 }),
  })
  context.show(target(8))
  assert.equal(loads, 1)
  assert.equal(context.video.muted, true)
  context.seek()
  assert.equal(context.video.currentTime, 8)
  context.show(target(12))
  assert.equal(loads, 1)
  assert.equal(context.video.currentTime, 12)
  assert.equal(context.preview.style.top, '422px')
  assert.equal(context.preview.style.left, '348px')
})

test('unavailable HLS falls back only once', () => {
  let loads = 0
  const context = {
    ...TextEditorPreviewHook,
    el: { dataset: { fallbackSrc: '/original' } },
    currentSource: '/playlist.m3u8',
    video: { load() { loads++ }, classList: { add() {} } },
    status: { dataset: { unavailable: 'Unavailable' } },
  }
  context.fallback()
  assert.equal(context.video.src, '/original')
  assert.equal(loads, 1)
  context.fallback()
  assert.equal(loads, 1)
  assert.equal(context.status.textContent, 'Unavailable')
})

test('textarea height follows its contents while preserving the editor scroll position', () => {
  const textarea = { style: {}, scrollHeight: 48 }
  const context = { scrollArea: { scrollTop: 180 } }
  TextEditorPreviewHook.resizeTextarea.call(context, textarea)
  assert.equal(textarea.style.height, '50px')
  assert.equal(context.scrollArea.scrollTop, 180)
})
