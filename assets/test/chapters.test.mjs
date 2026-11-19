import { test } from 'node:test'
import assert from 'node:assert/strict'

import { ChaptersHook, chapterCues } from '../js/hooks/chapters.js'

test('chapters end where the next one starts, and the last one with the video', () => {
  const chapters = [
    { start: 60, title: 'Second' },
    { start: 0, title: 'First' },
    { start: 30, title: '' },
    { start: Number.NaN, title: 'Broken' },
  ]

  assert.deepEqual(chapterCues(chapters, 90), [
    { start: 0, end: 60, title: 'First' },
    { start: 60, end: 90, title: 'Second' },
  ])
  assert.deepEqual(chapterCues([{ start: 95, title: 'Late' }], 90), [{ start: 95, end: 96, title: 'Late' }])
  assert.deepEqual(chapterCues([], 90), [])
})

function fakeVideo() {
  const tracks = []
  return {
    textTracks: tracks,
    duration: 90,
    addTextTrack(kind, label) {
      const cues = []
      const track = {
        kind,
        label,
        mode: 'disabled',
        cues,
        addCue: (cue) => cues.push(cue),
        removeCue: (cue) => cues.splice(cues.indexOf(cue), 1),
      }
      tracks.push(track)
      return track
    },
  }
}

function mountHook(chapters) {
  const listeners = {}
  const player = { shadowRoot: { querySelector: () => null }, scrollIntoView() {} }
  const container = { querySelector: () => player }

  globalThis.VTTCue = class {
    constructor(startTime, endTime, text) {
      Object.assign(this, { startTime, endTime, text })
    }
  }
  globalThis.document = {
    getElementById: (id) => (id === 'player-1' ? container : null),
    addEventListener: (name, listener) => (listeners[name] = listener),
    removeEventListener: (name) => delete listeners[name],
  }

  const hook = Object.create(ChaptersHook)
  hook.el = {
    dataset: { playerContainer: 'player-1', duration: '90', chapters: JSON.stringify(chapters) },
    addEventListener() {},
    removeEventListener() {},
    contains: () => true,
  }
  hook.mounted()
  return { hook, player, listeners }
}

test('the draft is shown on the player once it announces its video element', () => {
  const { hook, player, listeners } = mountHook([
    { start: 0, title: 'First' },
    { start: 60, title: 'Second' },
  ])
  const video = fakeVideo()

  // The player announces the element before attaching it to its shadow root.
  listeners['mave:video_element_ready']({ target: player, detail: video })

  assert.equal(video.textTracks.length, 1)
  const [track] = video.textTracks
  assert.equal(track.kind, 'chapters')
  assert.equal(track.mode, 'hidden')
  assert.deepEqual(
    track.cues.map((cue) => [cue.startTime, cue.endTime, cue.text]),
    [[0, 60, 'First'], [60, 90, 'Second']],
  )

  hook.el.dataset.chapters = JSON.stringify([{ start: 10, title: 'Only' }])
  hook.updated()
  assert.equal(video.textTracks.length, 1)
  assert.deepEqual(track.cues.map((cue) => [cue.startTime, cue.endTime, cue.text]), [[10, 90, 'Only']])

  hook.seek(42)
  assert.equal(video.currentTime, 42)

  hook.destroyed()
  assert.deepEqual(track.cues, [])
  assert.equal(listeners['mave:video_element_ready'], undefined)
})

test("another player's video element is ignored", () => {
  const { listeners } = mountHook([{ start: 0, title: 'First' }])
  const video = fakeVideo()

  listeners['mave:video_element_ready']({ target: {}, detail: video })
  assert.equal(video.textTracks.length, 0)
})
