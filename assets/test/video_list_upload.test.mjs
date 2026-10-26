import { test } from 'node:test'
import assert from 'node:assert/strict'
import { VideoListUploadHook, droppedFiles, hasFiles, MAX_CONCURRENT_UPLOADS } from '../js/hooks/video_list_upload.js'

class Element {
  constructor(dataset = {}) {
    this.dataset = dataset
    this.attributes = new Map()
    this.elements = new Map()
    this.events = new Map()
    this.style = {}
    this.textContent = ''
    const classes = new Set()
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, force) => force ? classes.add(name) : classes.delete(name),
    }
  }
  querySelector(selector) {
    if (!this.elements.has(selector)) this.elements.set(selector, new Element())
    return this.elements.get(selector)
  }
  addEventListener(name, handler) {
    if (!this.events.has(name)) this.events.set(name, new Set())
    this.events.get(name).add(handler)
  }
  removeEventListener(name, handler) { this.events.get(name)?.delete(handler) }
  fire(name, detail = {}) { this.events.get(name)?.forEach((handler) => handler({ detail })) }
  closest() { return this.dataset.targetFolderId ? this : this.parent?.closest() }
  contains(element) { return element === this || (!!element?.parent && this.contains(element.parent)) }
  setAttribute(name, value) { this.attributes.set(name, value); this.observer?.() }
  removeAttribute(name) { this.attributes.delete(name) }
  hasAttribute(name) { return this.attributes.has(name) }
  getAttribute(name) { return this.attributes.get(name) }
  appendChild(child) { child.parent = this; this.children = [...(this.children || []), child] }
  replaceChildren(...children) { this.children = children; children.forEach(child => { child.parent = this }) }
  cloneNode() { return new Element() }
  remove() { this.removed = true }
}

const file = { name: 'Launch.mp4', size: 1024, type: 'video/mp4' }

function drag(target, files = [file]) {
  return {
    target,
    dataTransfer: { types: ['Files'], files, items: files.map(() => ({ kind: 'file' })) },
    preventDefault() { this.prevented = true },
    stopPropagation() { this.stopped = true },
  }
}

function setup({ ready = true, reply = { ok: true, token: 'test-token', href: '/videos/new' } } = {}) {
  globalThis.window = new Element()
  globalThis.customElements = { whenDefined: () => Promise.resolve() }
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback }
    observe(element) { this.element = element; element.observer = this.callback }
    disconnect() { if (this.element) this.element.observer = null }
  }
  const uploads = []
  globalThis.document = {
    createElement() {
      const upload = new Element()
      upload.isSupportedFile = (candidate) => candidate.type === 'video/mp4'
      upload.upload = (candidate) => { upload.calls = [...(upload.calls || []), candidate] }
      if (ready) upload.setAttribute('ready', '')
      uploads.push(upload)
      return upload
    },
  }
  const el = new Element({
    destination: 'Videos', dropLabel: 'drop to upload', dropFolderLabel: 'drop to upload to %{folder}', uploadDisabled: 'false',
    invalidFileMessage: 'Unsupported file', queuedMessage: 'Waiting', completedMessage: 'Ready',
    busyMessage: 'Please wait', preparingMessage: 'Preparing', uploadingMessage: 'Uploading',
    processingMessage: 'Processing', connectionMessage: 'Connection lost', errorMessage: 'Upload failed',
    disabledMessage: 'Not allowed',
  })
  el.querySelector('[data-upload-template]').content = { firstElementChild: new Element() }
  const requests = []
  const hook = {
    ...VideoListUploadHook, el,
    // LiveView supplies this method on every hook; component state must not shadow it.
    upload() { throw new Error('LiveView upload must not be called by this hook') },
    pushEvent(name, params, callback) { requests.push({ name, params }); callback(typeof reply === 'function' ? reply(params) : reply) },
  }
  hook.mounted()
  return { hook, el, requests, uploads }
}

const files = (count) => Array.from({ length: count }, (_, i) => ({ ...file, name: `Video ${i + 1}.mp4` }))
async function until(predicate) {
  for (let i = 0; i < 100 && !predicate(); i++) await Promise.resolve()
  assert.ok(predicate(), 'expected queue transition')
}

test('multiple files are accepted; folders and empty drops are rejected', () => {
  const selection = files(4)
  assert.deepEqual(droppedFiles(drag(null, selection).dataTransfer).files, selection)
  assert.equal(droppedFiles(drag(null, []).dataTransfer).error, 'invalidFileMessage')
  const directory = drag(null).dataTransfer
  directory.items[0].webkitGetAsEntry = () => ({ isDirectory: true })
  assert.equal(droppedFiles(directory).error, 'invalidFileMessage')
})

test('multi-file hover highlights the exact folder without capturing internal moves', () => {
  const { hook, el } = setup()
  const folder = new Element({ targetFolderId: 'folder-id', uploadFolderName: 'Campaigns' })
  folder.parent = el
  const label = new Element()
  label.parent = folder
  const event = drag(label, files(4))
  hook.dragOver(event)
  assert.equal(el.dataset.dropActive, 'true')
  assert.ok(folder.hasAttribute('data-file-drop-target'))
  assert.equal(el.querySelector('[data-drop-label]').textContent, 'drop to upload to Campaigns')
  assert.equal(event.dataTransfer.dropEffect, 'copy')
  hook.dragOver(drag(el))
  assert.ok(!folder.hasAttribute('data-file-drop-target'))
  assert.equal(el.querySelector('[data-drop-label]').textContent, 'drop to upload')
  hook.clearDrag()
  const internal = { dataTransfer: { types: ['text/plain'] }, preventDefault() { throw Error('internal drag intercepted') } }
  assert.equal(hasFiles(internal), false)
  hook.dragOver(internal)
  assert.equal(el.dataset.dropActive, 'false')
  hook.destroyed()
})

test('three files upload concurrently; only server acknowledgment releases a queue slot', async () => {
  const { hook, el, requests, uploads } = setup()
  hook.drop(drag(el, files(5)))
  await until(() => uploads.filter(upload => upload.calls).length === MAX_CONCURRENT_UPLOADS)
  assert.equal(requests.length, 3)
  assert.equal(hook.entries.filter(entry => entry.state === 'queued').length, 2)
  assert.equal(typeof hook.upload, 'function', 'LiveView upload API is not shadowed')
  const row = hook.entries[0].row
  const progressFill = row.querySelector('[data-progress-fill]')
  assert.ok(progressFill.classList.contains('hidden'))
  uploads[0].fire('progress', { progress: 37.4 })
  assert.equal(progressFill.style.width, '37%')
  assert.ok(!progressFill.classList.contains('hidden'))
  assert.equal(row.querySelector('[data-upload-progress]').getAttribute('aria-valuenow'), 37)
  uploads[0].fire('progress', { progress: 100 })
  assert.equal(requests.length, 3)
  assert.equal(hook.pending(), true)
  uploads[0].fire('processing')
  await until(() => uploads[3]?.calls)
  assert.equal(requests.length, 4)
  assert.equal(hook.entries[0].file, null)
  assert.ok(row.querySelector('[data-upload-progress]').classList.contains('hidden'))
  uploads[1].fire('processing')
  await until(() => uploads[4]?.calls)
  uploads[2].fire('processing')
  uploads[3].fire('processing')
  uploads[4].fire('processing')
  assert.equal(hook.pending(), false)
  hook.destroyed()
})

test('new drops join an active queue and retain each drop destination', async () => {
  const { hook, el, requests, uploads } = setup()
  el.dataset.folderId = 'parent'
  hook.drop(drag(el, files(3)))
  await until(() => uploads[2]?.calls)
  const folder = new Element({ targetFolderId: 'nested', uploadFolderName: 'Campaigns' })
  folder.parent = el
  hook.drop(drag(folder, files(2)))
  assert.equal(hook.entries.length, 5)
  assert.equal(requests.length, 3)
  el.dataset.folderId = 'changed-after-drop'
  uploads[0].fire('processing')
  uploads[1].fire('processing')
  await until(() => requests.length === 5)
  assert.deepEqual(requests.map(request => request.params.folder_id), ['parent', 'parent', 'parent', 'nested', 'nested'])
  assert.ok(requests.every(request => request.params.file_count === 1))
  assert.equal(hook.entries[4].destination, 'Campaigns')
  hook.destroyed()
})

test('unsupported and empty files fail individually while valid files upload', async () => {
  const { hook, el, requests, uploads } = setup()
  hook.drop(drag(el, [{ ...file, type: 'image/png', name: 'Poster.png' }, { ...file, size: 0 }, file]))
  await until(() => uploads.some(upload => upload.calls))
  assert.equal(requests.length, 1)
  assert.deepEqual(hook.entries.map(entry => entry.state), ['error', 'error', 'uploading'])
  el.dataset.uploadDisabled = 'true'
  hook.drop(drag(el, files(2)))
  assert.equal(hook.entries.length, 3)
  assert.equal(el.querySelector('[data-upload-notice]').textContent, 'Not allowed')
  hook.destroyed()
})

test('a server rejection leaves no transfer and does not block the rest of the batch', async () => {
  const { hook, el, requests, uploads } = setup({ reply: params => params.name === 'Video 1.mp4' ?
    { ok: false, error: 'Upload limit reached' } : { ok: true, token: 'test-token', href: '/videos/new' } })
  hook.drop(drag(el, files(4)))
  await until(() => uploads.filter(upload => upload.calls).length === 3)
  assert.equal(requests.length, 4)
  assert.equal(uploads[0].calls, undefined)
  assert.equal(hook.entries[0].state, 'error')
  assert.equal(hook.entries[0].row.querySelector('[data-upload-message]').textContent, 'Upload limit reached')
  hook.destroyed()
})

test('retry uses the same video token and stays within the concurrency limit', async () => {
  const { hook, el, requests, uploads } = setup()
  hook.drop(drag(el, files(4)))
  await until(() => uploads[2]?.calls)
  uploads[0].fire('failed', { message: 'Network error' })
  await until(() => uploads[3]?.calls)
  assert.equal(hook.entries[0].state, 'error')
  assert.ok(!hook.entries[0].row.querySelector('[data-upload-retry]').classList.contains('hidden'))
  hook.retry(hook.entries[0])
  assert.equal(hook.entries[0].state, 'queued')
  assert.equal(uploads[0].calls.length, 1)
  uploads[1].fire('processing')
  await until(() => uploads[0].calls.length === 2)
  assert.equal(requests.length, 4, 'retry does not create another video')
  assert.equal(hook.entries[0].state, 'uploading')
  hook.destroyed()
})

test('each file waits for its own connection and destroying the list prevents late transfers', async () => {
  const { hook, el, uploads } = setup({ ready: false })
  hook.drop(drag(el, files(4)))
  await until(() => uploads[2]?.observer)
  assert.ok(uploads.every(upload => !upload.calls))
  uploads[0].setAttribute('ready', '')
  await until(() => uploads[0].calls)
  assert.equal(uploads[1].calls, undefined)
  hook.destroyed()
  await until(() => uploads.every(upload => upload.removed))
  assert.equal(uploads[1].calls, undefined)
  assert.equal(uploads.length, 3, 'waiting file was never started')
  assert.ok(Array.from(window.events.values()).every(listeners => listeners.size === 0))
})

test('late processing errors do not turn an acknowledged upload into a retryable failure', async () => {
  const { hook, el, uploads } = setup()
  hook.drop(drag(el))
  await until(() => uploads[0]?.calls)
  uploads[0].fire('processing')
  uploads[0].fire('error', { message: 'Processing failed' })
  assert.equal(hook.entries[0].state, 'processing')
  assert.equal(hook.entries[0].file, null)
  uploads[0].fire('completed')
  assert.equal(hook.entries[0].state, 'completed')
  assert.ok(uploads[0].removed)
  hook.destroyed()
})

test('in-app navigation cannot silently discard queued files', async () => {
  const { hook, el, uploads } = setup()
  hook.drop(drag(el, files(4)))
  await until(() => uploads[2]?.calls)
  let confirmations = 0
  window.confirm = () => { confirmations++; return false }
  const onClick = [...window.events.get('click')][0]
  const navigation = {
    button: 0, target: { closest: () => ({ target: '' }) },
    preventDefault() { this.prevented = true },
    stopImmediatePropagation() { this.stopped = true },
  }
  onClick(navigation)
  assert.ok(navigation.prevented && navigation.stopped)
  assert.equal(confirmations, 1)
  onClick({ ...navigation, metaKey: true })
  assert.equal(confirmations, 1, 'opening a separate tab does not discard uploads')
  hook.destroyed()
})
