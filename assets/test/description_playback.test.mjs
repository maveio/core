import { test } from 'node:test'
import assert from 'node:assert/strict'
import { repeatedStep, descriptionTrack, selectEditorSubtitle, selectAudioTrack, offsetPlayback, findEditorPlayer, findAudioMenu, DescriptionPlaybackHook, nextSeekStep } from '../js/hooks/description_playback.js'

test('selects the matching AD and does not guess between ambiguous tracks', () => {
  const tracks = [{ id: 'original', label: 'Dutch', language: 'nl' }, { id: 'ad', label: 'Dutch (AD)', language: 'nl' }]
  assert.equal(descriptionTrack({ tracks }, 'Dutch (AD)', 'nl').id, 'ad')
  assert.equal(descriptionTrack({ tracks }, 'Dutch (AD)', 'en'), null)
  assert.equal(descriptionTrack({ tracks: [...tracks, tracks[1]] }, 'Dutch (AD)', 'nl'), null)
})

test('audio selection uses the existing player event without replacing its source', () => {
  const menu = {
    selected: 'original',
    dispatchEvent(event) {
      assert.equal(event.type, 'mediaaudiotrackrequest')
      assert.equal(event.bubbles, true)
      assert.equal(event.composed, true)
      this.selected = event.detail
    },
  }
  assert.equal(selectAudioTrack(menu, { id: 'ad' }), true)
  assert.equal(menu.selected, 'ad')
})

test('skipping is clamped to the current video', () => {
  const player = { currentTime: 2 }
  offsetPlayback(player, -5, 20)
  assert.equal(player.currentTime, 0)
  offsetPlayback(player, 5, 20)
  assert.equal(player.currentTime, 5)
  offsetPlayback(player, 50, 20)
  assert.equal(player.currentTime, 20)
})

test('acceleration keeps three fine steps before increasing to five and ten seconds', () => {
  let seek = null
  const jumps = []
  for (let click = 0; click < 9; click++) {
    seek = nextSeekStep(seek, 1, click * 200)
    jumps.push(seek.seconds)
  }
  assert.deepEqual(jumps, [1, 1, 1, 5, 5, 5, 10, 10, 10])
  assert.equal(nextSeekStep(seek, 1, 2400).seconds, 1)
})

test('changing direction always starts with a small jump', () => {
  let seek = null
  for (let click = 0; click < 5; click++) seek = nextSeekStep(seek, -1, click * 100)
  assert.equal(seek.seconds, -5)
  assert.equal(nextSeekStep(seek, 1, 500).seconds, 1)
})

test('controls find only the editor video and its audio menu', () => {
  const expected = { getAttribute: () => 'selected' }
  const root = { querySelectorAll: () => [{ getAttribute: () => 'other' }, expected] }
  assert.equal(findEditorPlayer('selected', root), expected)
  const menu = {}
  const themeRoot = { querySelector: () => menu }
  const playerRoot = { querySelector: () => null, querySelectorAll: () => [{ shadowRoot: themeRoot }] }
  assert.equal(findAudioMenu(playerRoot), menu)
})

test('play selects the AD track before starting and makes audio audible', async () => {
  const calls = []
  const context = {
    sync() {},
    track: { id: 'ad' },
    menu: { selected: 'original', dispatchEvent(event) { calls.push('select'); this.selected = event.detail } },
    player: { paused: true, muted: true, async play() { calls.push('play') } },
  }
  await DescriptionPlaybackHook.toggle.call(context)
  assert.deepEqual(calls, ['select', 'play'])
  assert.equal(context.player.muted, false)
})

test('pause does not restart playback or switch tracks', async () => {
  let pauses = 0
  const context = {
    sync() {}, track: { id: 'ad' },
    player: { paused: false, pause() { pauses++ } },
  }
  await DescriptionPlaybackHook.toggle.call(context)
  assert.equal(pauses, 1)
})

test('playback failure is shown without an unhandled rejection', async () => {
  let errors = 0
  const context = {
    sync() {}, showError() { errors++ },
    track: { id: 'ad' }, menu: { selected: 'ad' },
    player: { paused: true, async play() { throw new Error('blocked') } },
  }
  await DescriptionPlaybackHook.toggle.call(context)
  assert.equal(errors, 1)
  assert.equal(context.starting, false)
})


test('even a short pause resets acceleration while rapid clicks keep it', () => {
  let seek = null
  for (const at of [0, 100, 200, 300]) seek = nextSeekStep(seek, 1, at)
  assert.equal(seek.seconds, 5)
  seek = nextSeekStep(seek, 1, 650)
  assert.equal(seek.seconds, 1)
  for (const at of [1000, 1350, 1700, 2050]) {
    seek = nextSeekStep(seek, 1, at)
    assert.equal(seek.seconds, 1)
  }
})

test('subtitle playback uses the current audio and preserves mute', async () => {
  let plays = 0
  const context = {
    subtitle: true, sync() {},
    player: { paused: true, muted: true, async play() { plays++ } },
  }
  await DescriptionPlaybackHook.toggle.call(context)
  assert.equal(plays, 1)
  assert.equal(context.player.muted, true)
})

test('opening captions overrides the player default and closing restores the previous selection', () => {
  const player = new EventTarget()
  let language
  player.addEventListener('mediashowsubtitlesrequest', event => { language = event.detail[0].language })
  const track = (srclang, src, mode) => Object.assign(new EventTarget(), { kind: 'subtitles', srclang, src, track: { mode } })
  const original = track('en', 'original.vtt', 'showing')
  const other = track('nl', 'other.vtt', 'disabled')
  const edited = track('nl', 'edited.vtt', 'disabled')
  const tracks = [original, other, edited]
  assert.equal(selectEditorSubtitle(player, tracks, 'NL', 'missing.vtt'), null)
  const selection = selectEditorSubtitle(player, tracks, 'NL', 'edited.vtt')
  assert.equal(language, 'nl')
  assert.deepEqual(tracks.map(el => el.track.mode), ['disabled', 'disabled', 'showing'])
  let visible = 'nl'
  player.addEventListener('mediadisablesubtitlesrequest', () => { visible = null })
  original.addEventListener('cuechange', () => { visible = 'en' })
  DescriptionPlaybackHook.unbindPlayer.call({ player, subtitleSelection: selection, onMedia() {} })
  assert.deepEqual(tracks.map(el => el.track.mode), ['showing', 'disabled', 'disabled'])
  assert.equal(visible, 'en')

  original.track.mode = 'disabled'
  const preview = selectEditorSubtitle(player, tracks, 'NL', 'edited.vtt')
  visible = 'nl'
  DescriptionPlaybackHook.unbindPlayer.call({ player, subtitleSelection: preview, onMedia() {} })
  assert.deepEqual(tracks.map(el => el.track.mode), ['disabled', 'disabled', 'disabled'])
  assert.equal(visible, null)
})

test('playing a moment seeks to its exact timestamp even during playback', async () => {
  for (const moment of [0, 0.2, 7]) {
    let played = false
    const player = { paused: false, currentTime: 20, play() { played = true } }
    await DescriptionPlaybackHook.toggle.call({ player, subtitle: true, sync() {} }, moment)
    assert.equal(player.currentTime, moment)
    assert.equal(played, true)
  }
})

test('rapid timestamp nudges advance in milliseconds and reset after a pause or reversal', () => {
  const sizes = [1, 10, 100, 1000]
  let step = null
  const deltas = []
  for (let n = 0; n < 11; n++) {
    step = repeatedStep(step, 1, n * 100, sizes)
    deltas.push(step.delta)
  }
  assert.deepEqual(deltas, [1, 1, 1, 10, 10, 10, 100, 100, 100, 1000, 1000])
  assert.equal(repeatedStep(step, -1, 1100, sizes).delta, -1)
  assert.equal(repeatedStep(step, 1, 1350, sizes).delta, 1)
})
