import { Fragment, Schema, Slice } from "prosemirror-model"
import { EditorState, Plugin, PluginKey, TextSelection } from "prosemirror-state"
import { EditorView, Decoration, DecorationSet } from "prosemirror-view"
import { baseKeymap } from "prosemirror-commands"
import { history, undo, redo } from "prosemirror-history"
import { keymap } from "prosemirror-keymap"
import { InputRule, inputRules } from "prosemirror-inputrules"
import { findEditorPlayer, repeatedStep } from "./description_playback.js"

export function formatMoment(seconds) {
  const ms = Math.round(seconds * 1000)
  const hours = Math.floor(ms / 3600000)
  const minutes = Math.floor(ms / 60000) % 60
  const rest = `${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}.${String(ms % 1000).padStart(3, "0")}`
  return `${hours ? `${String(hours).padStart(2, "0")}:` : ""}${String(hours ? minutes : Math.floor(ms / 60000)).padStart(2, "0")}:${rest}`
}

export function parseMoment(value) {
  if (!/^\d{1,3}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?$/.test(value.trim())) return null
  const parts = value.trim().replace(",", ".").split(":").map(Number)
  if (parts.slice(1).some(value => value >= 60)) return null
  return parts.reduce((sum, value) => sum * 60 + value, 0)
}

export const descriptionSchema = new Schema({
  nodes: {
    doc: { content: "paragraph+" },
    paragraph: { content: "inline*", group: "block", toDOM: () => ["p", 0], parseDOM: [{ tag: "p" }] },
    text: { group: "inline" },
    hard_break: { inline: true, group: "inline", selectable: false, toDOM: () => ["br"], parseDOM: [{ tag: "br" }] },
    moment: {
      inline: true, group: "inline", atom: true,
      attrs: { id: {}, start: {}, end: { default: null } },
      leafText: node => `[${formatMoment(node.attrs.start)}]`,
      toDOM: node => ["span", { "data-moment": node.attrs.id, "data-start": node.attrs.start, "data-end": node.attrs.end }, `[${formatMoment(node.attrs.start)}]`],
      parseDOM: [{ tag: "span[data-moment]", getAttrs: el => ({ id: el.dataset.moment, start: Number(el.dataset.start), end: el.dataset.end ? Number(el.dataset.end) : null }) }],
    },
  },
})

export function replaceWithMoment(state, from, to, time, id) {
  const node = descriptionSchema.nodes.moment.create({ id, start: time })
  const transaction = state.tr.delete(from, to)
  let position = from
  if (transaction.doc.resolve(position).nodeBefore?.type === descriptionSchema.nodes.hard_break) {
    transaction.delete(position - 1, position)
    position--
  }
  if (transaction.doc.resolve(position).parentOffset > 0) {
    transaction.split(position)
    position += 2
  }
  const beforeLabel = transaction.doc.resolve(position).nodeAfter?.type === descriptionSchema.nodes.moment
  transaction.insert(position, [node, descriptionSchema.text(" ")])
  if (beforeLabel) transaction.split(position + 2)
  return transaction.setSelection(TextSelection.create(transaction.doc, position + 2))
}

export function addTimedLine(state, cursor, windows, duration, id) {
  const anchors = []
  state.doc.forEach((paragraph, position) => {
    paragraph.forEach((node, offset) => {
      if (node.type === descriptionSchema.nodes.moment) {
        anchors.push({ position, label: position + 1 + offset, attrs: node.attrs })
      }
    })
  })
  let index = anchors.findLastIndex(anchor => cursor != null && anchor.position < cursor)
  if (index < 0 && anchors[0]?.attrs.start === 0) index = 0
  // Keep simultaneous existing cues together.
  while (index >= 0 && anchors[index + 1]?.attrs.start === anchors[index].attrs.start) index++
  const previous = anchors[index]
  const next = anchors[index + 1]
  const limit = Math.ceil((next?.attrs.start ?? duration) * 1000)
  const tr = state.tr
  let start = 0
  if (previous) {
    const previousStart = Math.round(previous.attrs.start * 1000)
    const end = previous.attrs.end ?? windows.find(window => window.id === previous.attrs.id)?.end
    let ms = Math.max(previousStart + 1, Math.round((end ?? previous.attrs.start + 1) * 1000))
    if (ms >= limit) ms = Math.floor((previousStart + limit) / 2)
    if (ms <= previousStart) return null
    start = ms / 1000
    if (previous.attrs.end > start) tr.setNodeMarkup(previous.label, null, { ...previous.attrs, end: start })
  }
  if (start * 1000 >= limit) return null
  const label = [descriptionSchema.nodes.moment.create({ id, start }), descriptionSchema.text(" ")]
  const caret = cursor == null ? null : state.doc.resolve(cursor)
  if (caret?.parent.type === descriptionSchema.nodes.paragraph &&
      (!previous || previous.label < cursor) && (!next || cursor < next.position)) {
    if (!caret.parent.content.size) {
      tr.insert(cursor, label)
      return tr.setSelection(TextSelection.create(tr.doc, cursor + 2))
    }
    if (caret.nodeBefore?.type === descriptionSchema.nodes.hard_break && !caret.nodeAfter) {
      tr.delete(cursor - 1, cursor)
      tr.split(cursor - 1)
      tr.insert(cursor + 1, label)
      return tr.setSelection(TextSelection.create(tr.doc, cursor + 3))
    }
  }
  let insertAt = next?.position ?? state.doc.content.size
  const cue = descriptionSchema.nodes.paragraph.create(null, label)
  if (state.doc.childCount === 1 && !state.doc.firstChild.content.size) {
    tr.replaceWith(0, state.doc.content.size, cue)
    insertAt = 0
  } else {
    tr.insert(insertAt, cue)
  }
  return tr.setSelection(TextSelection.create(tr.doc, insertAt + 3))
}

// The leading timestamp and playback controls belong to the cue, outside its text.
export function cueTextCaret(selection) {
  const cursor = selection.$cursor
  if (cursor?.parentOffset === 0 && cursor.nodeAfter?.type === descriptionSchema.nodes.moment) {
    return TextSelection.create(cursor.doc, cursor.pos + cursor.nodeAfter.nodeSize)
  }
  return selection
}

export const momentDeletionKey = new PluginKey("momentDeletion")

export function momentDeletionPlugin() {
  const clear = view => {
    if (momentDeletionKey.getState(view.state)) view.dispatch(view.state.tr.setMeta(momentDeletionKey, null))
    return false
  }
  return new Plugin({
    key: momentDeletionKey,
    state: {
      init: () => null,
      apply: (tr, previous) => {
        const next = tr.getMeta(momentDeletionKey)
        if (next !== undefined) return next
        return tr.docChanged || tr.selectionSet ? null : previous
      },
    },
    props: {
      handleKeyDown: (view, event) => event.key === "Backspace" ? false : clear(view),
      handleDOMEvents: { mousedown: clear, blur: clear },
    },
  })
}

export function backspaceMoment(state, dispatch) {
  const pending = momentDeletionKey.getState(state)
  if (pending && state.doc.nodeAt(pending.position)?.attrs.id === pending.id) {
    if (dispatch) dispatch(state.tr.delete(pending.position, pending.position + 1).setMeta(momentDeletionKey, null))
    return true
  }
  const { selection } = state
  if (!selection.empty) return false
  const { $from } = selection
  let before = $from.nodeBefore
  let position = $from.pos
  if (before?.isText && /^[ \t\u00a0]+$/.test(before.text)) {
    position -= before.nodeSize
    before = state.doc.resolve(position).nodeBefore
  }
  if (before?.type.name !== "moment") return false
  if (dispatch) dispatch(state.tr.setMeta(momentDeletionKey, { position: position - before.nodeSize, id: before.attrs.id }))
  return true
}

export function subtitleLineBreak(state, dispatch) {
  if (dispatch) dispatch(state.tr.replaceSelectionWith(descriptionSchema.nodes.hard_break.create()).scrollIntoView())
  return true
}

export function subtitlePaste(slice) {
  if (slice.content.childCount < 2) return slice
  for (let i = 0; i < slice.content.childCount; i++) {
    if (slice.content.child(i).type !== descriptionSchema.nodes.paragraph) return slice
  }
  let hasLabel = false
  slice.content.descendants(node => { if (node.type === descriptionSchema.nodes.moment) hasLabel = true })
  if (hasLabel) return slice
  const lines = []
  slice.content.forEach((paragraph, _offset, index) => {
    if (index) lines.push(descriptionSchema.nodes.hard_break.create())
    paragraph.content.forEach(node => lines.push(node))
  })
  return new Slice(Fragment.from(lines), 0, 0)
}

export function documentFromMoments(moments, kind) {
  const paragraphs = []
  for (const moment of moments) {
    const lines = moment.text.split("\n")
    let content = []
    lines.forEach((line, index) => {
      if (index && kind === "subtitle") content.push(descriptionSchema.nodes.hard_break.create())
      if (index === 0 && moment.start != null) content.push(descriptionSchema.nodes.moment.create({ id: moment.id, start: moment.start, end: moment.end }))
      if (line) content.push(descriptionSchema.text(line))
      else if (index === 0 && content.length) content.push(descriptionSchema.text(" "))
      if (kind !== "subtitle" || index === lines.length - 1) {
        paragraphs.push(descriptionSchema.nodes.paragraph.create(null, content))
        content = []
      }
    })
  }
  return descriptionSchema.nodes.doc.create(null, paragraphs.length ? paragraphs : [descriptionSchema.nodes.paragraph.create()])
}

export function momentsFromDocument(doc) {
  const moments = []
  const ends = new Map()
  let current = null
  doc.forEach((paragraph, paragraphPos, index) => {
    const paragraphEnd = paragraphPos + paragraph.nodeSize
    if (index && current) current.text += "\n"
    paragraph.forEach((node, offset) => {
      if (node.type.name === "moment") {
        if (current && offset > 0) ends.set(current.id, paragraphEnd)
        current = { id: node.attrs.id, start: node.attrs.start, text: "" }
        if (node.attrs.end != null) current.end = node.attrs.end
        moments.push(current)
      } else {
        if (!current) {
          current = { id: "unplaced", start: null, text: "" }
          moments.push(current)
        }
        current.text += node.isText ? node.text : "\n"
      }
    })
    if (current) ends.set(current.id, paragraphEnd)
  })
  return { moments: moments.map(m => ({ ...m, text: m.text.trim() })), ends }
}

function uniqueMoments() {
  return new Plugin({
    appendTransaction(_transactions, _old, state) {
      const seen = new Set()
      let tr = null
      state.doc.descendants((node, pos) => {
        if (node.type.name !== "moment") return
        if (seen.has(node.attrs.id) || node.attrs.id === "unplaced") {
          tr ||= state.tr
          tr.setNodeMarkup(pos, null, { ...node.attrs, id: crypto.randomUUID() })
        }
        seen.add(node.attrs.id)
      })
      return tr
    },
  })
}

export function activeMomentRange(doc, time, windows = []) {
  if (!Number.isFinite(time)) return null
  const anchors = []
  doc.descendants((node, position) => {
    if (node.type.name === "moment") anchors.push({ id: node.attrs.id, start: node.attrs.start, from: position })
  })
  const byId = new Map(windows.map(window => [window.id, window]))
  let active = -1
  anchors.forEach((anchor, index) => {
    const window = byId.get(anchor.id)
    if (window && window.start <= time && time < window.end && (active < 0 || anchor.start >= anchors[active].start)) active = index
  })
  return active < 0 ? null : { ...anchors[active], to: anchors[active + 1]?.from ?? doc.content.size }
}

export function stepMoment(doc, position, value, deltaMs, duration, editingEnd, cueEnd) {
  const time = parseMoment(value)
  if (time == null) return null
  let minMs = 0
  let maxMs = Math.ceil(duration * 1000) - 1
  if (editingEnd) {
    minMs = Math.round(doc.nodeAt(position).attrs.start * 1000) + 1
    maxMs = Math.floor(duration * 1000)
  } else {
    if (cueEnd != null) maxMs = Math.min(maxMs, Math.ceil(cueEnd * 1000) - 1)
    doc.descendants((node, pos) => {
      if (node.type.name !== "moment") return
      const ms = Math.round(node.attrs.start * 1000)
      if (pos < position) minMs = Math.max(minMs, ms + 1)
      if (pos > position) maxMs = Math.min(maxMs, ms - 1)
    })
  }
  if (minMs > maxMs) return null
  return formatMoment(Math.max(minMs, Math.min(maxMs, Math.round(time * 1000) + deltaMs)) / 1000)
}

export function invalidMomentIds(doc, duration = Infinity, originalStarts = new Map()) {
  const anchors = []
  doc.descendants(node => {
    if (node.type.name === "moment") anchors.push(node.attrs)
  })
  const ordered = (a, b) => a.start < b.start ||
    (a.start === b.start && originalStarts.get(a.id) === a.start && originalStarts.get(b.id) === b.start)
  return new Set(anchors.filter((anchor, index) =>
    !Number.isFinite(anchor.start) || anchor.start < 0 || anchor.start >= duration ||
    (index > 0 && !ordered(anchors[index - 1], anchor)) ||
    (index + 1 < anchors.length && !ordered(anchor, anchors[index + 1]))
  ).map(anchor => anchor.id))
}

export function invalidTypedTimeRanges(doc, duration = Infinity) {
  const anchors = []
  const ranges = []
  doc.descendants((node, position) => {
    if (node.type.name === "moment") anchors.push({ position, time: node.attrs.start })
  })
  doc.descendants((node, position) => {
    if (!node.isText) return
    for (const match of node.text.matchAll(/\[[0-9:.,-]*:[0-9:.,-]*\]/g)) {
      const from = position + match.index
      const time = parseMoment(match[0].slice(1, -1))
      const previous = anchors.filter(anchor => anchor.position < from).at(-1)
      const next = anchors.find(anchor => anchor.position > from)
      if (time == null || time >= duration || (previous && time <= previous.time) || (next && time >= next.time)) {
        ranges.push({ from, to: from + match[0].length })
      }
    }
  })
  return ranges
}

export const DescriptionDocumentHook = {
  mounted() {
    const initial = JSON.parse(this.el.dataset.document)
    this.originalStarts = new Map(this.el.dataset.kind === "subtitle" ? initial.map(m => [m.id, m.start]) : [])
    this.sequence = 0
    this.feedback = JSON.parse(this.el.dataset.feedback)
    this.playbackWindows = JSON.parse(this.el.dataset.playbackWindows || "[]")
    this.form = this.el.closest("form")
    this.hidden = this.form.querySelector("[data-description-document]")
    this.addButton = this.form.querySelector("[data-add-line]")
    const feedbackPlugin = new Plugin({ props: { decorations: state => this.decorations(state) } })
    const typedMoment = new InputRule(/\[(\d{1,3}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?)\] $/, (state, match, start, end) => {
      const time = parseMoment(match[1])
      if (time == null || time >= Number(this.el.dataset.duration)) return null
      return replaceWithMoment(state, start, end, time, crypto.randomUUID())
    })
    const subtitle = this.el.dataset.kind === "subtitle"
    const lineKeys = subtitle ? { Enter: subtitleLineBreak, "Shift-Enter": subtitleLineBreak } : {}
    const doc = documentFromMoments(initial, this.el.dataset.kind)
    this.view = new EditorView(this.el, {
      state: EditorState.create({
        doc, selection: cueTextCaret(TextSelection.atStart(doc)),
        plugins: [history(), keymap({ ...lineKeys, "Backspace": backspaceMoment, "Mod-z": undo, "Shift-Mod-z": redo, "Mod-y": redo }), keymap(baseKeymap), inputRules({ rules: [typedMoment] }), uniqueMoments(), momentDeletionPlugin(), feedbackPlugin],
      }),
      editable: () => this.el.dataset.readOnly !== "true",
      transformPasted: subtitle ? subtitlePaste : undefined,
      attributes: { class: "description-prose", role: "textbox", "aria-multiline": "true", "aria-label": this.el.dataset.label },
      nodeViews: { moment: (node, view, getPos, decorations) => this.momentView(node, view, getPos, decorations) },
      dispatchTransaction: transaction => {
        if (transaction.docChanged && this.el.dataset.readOnly === "true") return
        const selection = cueTextCaret(transaction.selection)
        if (selection !== transaction.selection) transaction.setSelection(selection)
        this.view.updateState(this.view.state.apply(transaction))
        if (transaction.docChanged) {
          this.linePicked = true
          this.pickedLabel = null
          this.changed()
        }
      },
    })
    this.pickLine = event => {
      if (event.target.closest("[data-play-moment]")) return
      this.linePicked = true
      const label = event.target.closest(".description-moment")
      this.pickedLabel = label ? this.view.posAtDOM(label, 0) : null
    }
    this.view.dom.addEventListener("focusin", this.pickLine)
    this.view.dom.addEventListener("pointerdown", this.pickLine)
    this.addLine = () => {
      const { state } = this.view
      const cursor = this.linePicked ? this.pickedLabel ?? state.selection.to : null
      const transaction = addTimedLine(state, cursor, this.playbackWindows,
        Number(this.el.dataset.duration), crypto.randomUUID())
      if (!transaction) {
        this.pushEventTo(this.form, "description_line_unavailable", {})
        return
      }
      this.view.dispatch(transaction.scrollIntoView())
      this.view.focus()
      this.linePicked = true
      this.pickedLabel = null
    }
    this.addButton.addEventListener("click", this.addLine)
    this.beforeSubmit = () => { this.hidden.value = JSON.stringify(momentsFromDocument(this.view.state.doc).moments) }
    this.form.addEventListener("submit", this.beforeSubmit, true)
    this.onPlayhead = event => {
      const time = event.detail.time
      const playbackChanged = event.detail.playing !== this.playing
      if (time === this.currentTime && !playbackChanged) return
      const before = activeMomentRange(this.view.state.doc, this.currentTime, this.playbackWindows)?.id
      this.currentTime = time
      this.playing = event.detail.playing
      if (playbackChanged || activeMomentRange(this.view.state.doc, time, this.playbackWindows)?.id !== before) this.view.updateState(this.view.state)
    }
    this.form.addEventListener("description:playhead", this.onPlayhead)
    this.currentTime = findEditorPlayer(this.form.dataset.playerEmbed)?.currentTime
    this.updated()
  },

  updated() {
    const readOnly = this.el.dataset.readOnly === "true"
    if (this.readOnly === readOnly) return
    this.readOnly = readOnly
    this.addButton.disabled = readOnly
    this.view.dom.setAttribute("aria-readonly", String(readOnly))
    this.view.updateState(this.view.state)
  },

  changed() {
    const { moments } = momentsFromDocument(this.view.state.doc)
    this.hidden.value = JSON.stringify(moments)
    const sequence = ++this.sequence
    this.pushEventTo(this.form, "change_description_document", { moments }, reply => {
      if (sequence !== this.sequence || this.destroyedEditor) return
      this.feedback = reply.groups || []
      this.playbackWindows = reply.windows || []
      this.view.updateState(this.view.state)
    })
  },

  decorations(state) {
    const { ends, moments } = momentsFromDocument(state.doc)
    const subtitle = this.el?.dataset.kind === "subtitle"
    const paceHints = subtitle ? new Map(this.feedback.map(group => [group.after_id, group.label])) : null
    const decorations = subtitle ? [] : this.feedback.flatMap(group => {
      const position = ends.get(group.after_id)
      const lastMoment = moments.find(moment => moment.id === group.after_id)
      if (position == null || !lastMoment || !group.count) return []
      return [Decoration.widget(position, () => {
        const span = document.createElement("span")
        span.className = `description-feedback ${group.state === "within" ? "" : "description-feedback-warning"}`
        span.contentEditable = "false"
        span.textContent = group.label
        if (group.start != null) span.title = `${formatMoment(group.start)} – ${formatMoment(group.end)}`
        return span
      }, { side: 1, key: JSON.stringify(group) })]
    })
    const active = activeMomentRange(state.doc, this.currentTime, this.playbackWindows)
    if (active) {
      decorations.push(Decoration.inline(active.from, active.to, { class: "description-active-text" }))
      decorations.push(Decoration.node(active.from, active.from + 1, { class: "description-active-moment", "aria-current": "true" }, { playing: !!this.playing }))
    }
    const ducking = new Set(this.playbackWindows.filter(window => window.ducks_speech).map(window => window.id))
    const invalid = invalidMomentIds(state.doc, Number(this.el?.dataset.duration ?? Infinity), this.originalStarts)
    const pending = momentDeletionKey.getState(state)
    if (pending) decorations.push(Decoration.node(pending.position, pending.position + 1, { class: "description-armed-moment" }))
    const cueEnds = subtitle
      ? new Map(this.playbackWindows.map(window => [window.id, window.end])) : null
    state.doc.descendants((node, position) => {
      if (node.type.name === "moment" && ducking.has(node.attrs.id)) {
        decorations.push(Decoration.node(position, position + 1, {
          "data-ducking": "true", title: this.el.dataset.duckingHint,
        }))
      }
      if (node.type.name === "moment" && cueEnds?.has(node.attrs.id)) {
        const end = cueEnds.get(node.attrs.id)
        const pace = paceHints.get(node.attrs.id) || ""
        decorations.push(Decoration.node(position, position + 1, { "data-cue-end": end, "data-reading-pace": pace }, { end, pace }))
      }
      if (node.type.name === "moment" && invalid.has(node.attrs.id)) {
        decorations.push(Decoration.node(position, position + 1, {
          class: "description-invalid-moment", "aria-invalid": "true",
          title: this.el?.dataset.invalidTimeLabel || "Invalid time order",
        }))
      }
    })
    for (const range of invalidTypedTimeRanges(state.doc, Number(this.el?.dataset.duration ?? Infinity))) {
      decorations.push(Decoration.inline(range.from, range.to, {
        class: "description-invalid-time", "aria-invalid": "true",
        title: this.el?.dataset.invalidTimeLabel || "Invalid time",
      }))
    }
    return DecorationSet.create(state.doc, decorations)
  },

  momentView(node, view, getPos, decorations) {
    const subtitle = this.el.dataset.kind === "subtitle"
    let cueTiming = decorations.find(d => d.spec.end != null)?.spec
    let playing = decorations.some(d => d.spec.playing)
    let current = node
    const dom = document.createElement("span")
    dom.className = "description-moment"
    dom.contentEditable = "false"
    const button = document.createElement("button")
    button.type = "button"
    button.className = "description-time"
    const endButton = subtitle ? button.cloneNode(false) : null
    const play = document.createElement("button")
    play.type = "button"
    play.className = "description-line-play"
    play.addEventListener("mousedown", event => event.preventDefault())
    const icon = document.createElement("span")
    icon.className = "hero-play size-3.5"
    icon.setAttribute("aria-hidden", "true")
    play.append(icon)
    const refresh = () => {
      button.textContent = formatMoment(current.attrs.start)
      button.dataset.previewTime = current.attrs.start
      play.dataset.playMoment = current.attrs.start
      play.toggleAttribute("data-pause-moment", playing)
      icon.classList.toggle("hero-play", !playing)
      icon.classList.toggle("hero-pause", playing)
      play.title = playing ? this.el.dataset.pauseMomentLabel : `${this.el.dataset.playMomentLabel} ${button.textContent}`
      play.setAttribute("aria-label", play.title)
      button.setAttribute("aria-label", `${subtitle ? this.el.dataset.startLabel : this.el.dataset.editTimeLabel} ${button.textContent}`)
      if (endButton) {
        const end = current.attrs.end ?? cueTiming?.end
        endButton.title = cueTiming?.pace || ""
        if (endButton.title) endButton.setAttribute("aria-description", endButton.title)
        else endButton.removeAttribute("aria-description")
        endButton.disabled = !Number.isFinite(end)
        if (endButton.disabled) delete endButton.dataset.previewTime
        else endButton.dataset.previewTime = end
        endButton.textContent = endButton.disabled ? "…" : formatMoment(end)
        endButton.setAttribute("aria-label", `${this.el.dataset.endLabel} ${endButton.textContent}`)
      }
    }
    refresh()
    dom.append(play, button)
    const volumeTemplate = this.form.querySelector("[data-original-volume-template]")
    if (volumeTemplate) dom.append(volumeTemplate.content.cloneNode(true))
    if (endButton) dom.append("–", endButton)
    const edit = (trigger, editingEnd) => {
      if (dom.querySelector("input")) return
      const input = document.createElement("input")
      input.type = "text"
      input.value = trigger.textContent
      input.className = "description-time-input"
      input.setAttribute("aria-label", trigger.getAttribute("aria-label"))
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "description-time-remove"
      remove.textContent = "×"
      remove.setAttribute("aria-label", this.el.dataset.removeTimeLabel)
      trigger.hidden = true
      trigger.after(input)
      if (!editingEnd) dom.append(remove)
      let closed = false
      const close = () => { closed = true; input.remove(); remove.remove(); trigger.hidden = false }
      const commit = (focusEditor = true) => {
        if (closed) return
        const time = parseMoment(input.value)
        const duration = Number(this.el.dataset.duration)
        const end = current.attrs.end ?? cueTiming?.end
        const invalid = editingEnd ? time <= current.attrs.start || time > duration
          : time >= duration || (subtitle && end != null && time >= end)
        if (time == null || invalid) {
          input.setAttribute("aria-invalid", "true")
          input.setCustomValidity(this.el.dataset.invalidTimeLabel)
          return
        }
        if (time !== (editingEnd ? end : current.attrs.start)) {
          const attrs = editingEnd ? { ...current.attrs, end: time }
            : { ...current.attrs, start: time, end: subtitle ? end : null }
          view.dispatch(view.state.tr.setNodeMarkup(getPos(), null, attrs))
        }
        close()
        if (focusEditor) view.focus()
      }
      let lastStep = null
      input.addEventListener("keydown", event => {
        if (event.key === "ArrowUp" || event.key === "ArrowDown") {
          event.preventDefault()
          event.stopPropagation()
          const direction = event.key === "ArrowUp" ? 1 : -1
          lastStep = event.shiftKey ? null : repeatedStep(lastStep, direction, performance.now(), [1, 10, 100, 1000])
          const value = stepMoment(view.state.doc, getPos(), input.value,
            lastStep?.delta ?? direction * 1000, Number(this.el.dataset.duration),
            editingEnd, subtitle ? current.attrs.end ?? cueTiming?.end : null)
          if (value != null) {
            input.value = value
            input.removeAttribute("aria-invalid")
            input.setCustomValidity("")
          }
        }
        if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); commit() }
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); view.focus() }
      })
      input.addEventListener("blur", event => { if (event.relatedTarget !== remove) commit(false) })
      remove.addEventListener("click", () => {
        view.dispatch(view.state.tr.delete(getPos(), getPos() + 1))
        view.focus()
      })
      input.focus()
      input.select()
    }
    button.addEventListener("click", () => edit(button, false))
    endButton?.addEventListener("click", () => edit(endButton, true))
    return {
      dom,
      stopEvent: () => true,
      ignoreMutation: () => true,
      update(updated, decorations) {
        if (updated.type !== current.type) return false
        current = updated
        cueTiming = decorations.find(d => d.spec.end != null)?.spec
        playing = decorations.some(d => d.spec.playing)
        refresh()
        return true
      },
    }
  },

  destroyed() {
    this.destroyedEditor = true
    this.form.removeEventListener("submit", this.beforeSubmit, true)
    this.form.removeEventListener("description:playhead", this.onPlayhead)
    this.view.dom.removeEventListener("focusin", this.pickLine)
    this.view.dom.removeEventListener("pointerdown", this.pickLine)
    this.addButton.removeEventListener("click", this.addLine)
    this.view.destroy()
  },
}
