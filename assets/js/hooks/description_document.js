import { Fragment, Schema, Slice } from "prosemirror-model"
import { EditorState, Plugin, PluginKey, TextSelection } from "prosemirror-state"
import { EditorView, Decoration, DecorationSet } from "prosemirror-view"
import { baseKeymap } from "prosemirror-commands"
import { history, undo, redo } from "prosemirror-history"
import { keymap } from "prosemirror-keymap"
import { InputRule, inputRules } from "prosemirror-inputrules"
import { findEditorPlayer } from "./description_playback.js"

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
  transaction.insert(position, [node, descriptionSchema.text(" ")])
  return transaction.setSelection(TextSelection.create(transaction.doc, position + 2))
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
    this.addButton = this.form.querySelector("[data-add-moment]")
    const feedbackPlugin = new Plugin({ props: { decorations: state => this.decorations(state) } })
    const typedMoment = new InputRule(/\[(\d{1,3}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?)\] $/, (state, match, start, end) => {
      const time = parseMoment(match[1])
      if (time == null || time >= Number(this.el.dataset.duration)) return null
      return replaceWithMoment(state, start, end, time, crypto.randomUUID())
    })
    const subtitle = this.el.dataset.kind === "subtitle"
    const lineKeys = subtitle ? { Enter: subtitleLineBreak, "Shift-Enter": subtitleLineBreak } : {}
    this.view = new EditorView(this.el, {
      state: EditorState.create({
        doc: documentFromMoments(initial, this.el.dataset.kind),
        plugins: [history(), keymap({ ...lineKeys, "Backspace": backspaceMoment, "Mod-z": undo, "Shift-Mod-z": redo, "Mod-y": redo }), keymap(baseKeymap), inputRules({ rules: [typedMoment] }), uniqueMoments(), momentDeletionPlugin(), feedbackPlugin],
      }),
      transformPasted: subtitle ? subtitlePaste : undefined,
      attributes: { class: "description-prose", role: "textbox", "aria-multiline": "true", "aria-label": this.el.dataset.label },
      nodeViews: { moment: (node, view, getPos, decorations) => this.momentView(node, view, getPos, decorations) },
      dispatchTransaction: transaction => {
        this.view.updateState(this.view.state.apply(transaction))
        if (transaction.docChanged) this.changed()
      },
    })
    this.addMoment = () => {
      const player = findEditorPlayer(this.form.dataset.playerEmbed)
      const time = player?.currentTime
      if (!Number.isFinite(time) || time < 0) {
        this.pushEventTo(this.form, "description_player_unavailable", {})
        return
      }
      this.view.focus()
      const { state } = this.view
      this.view.dispatch(replaceWithMoment(state, state.selection.from, state.selection.to,
        Math.floor(Math.min(time, Number(this.el.dataset.duration) - 0.001) * 1000) / 1000, crypto.randomUUID()).scrollIntoView())
    }
    this.addButton.addEventListener("click", this.addMoment)
    this.beforeSubmit = () => { this.hidden.value = JSON.stringify(momentsFromDocument(this.view.state.doc).moments) }
    this.form.addEventListener("submit", this.beforeSubmit, true)
    this.onPlayhead = event => {
      const time = event.detail.time
      if (time === this.currentTime) return
      const before = activeMomentRange(this.view.state.doc, this.currentTime, this.playbackWindows)?.id
      this.currentTime = time
      if (activeMomentRange(this.view.state.doc, time, this.playbackWindows)?.id !== before) this.view.updateState(this.view.state)
    }
    this.form.addEventListener("description:playhead", this.onPlayhead)
    this.currentTime = findEditorPlayer(this.form.dataset.playerEmbed)?.currentTime
    this.view.updateState(this.view.state)
  },

  changed() {
    const { moments } = momentsFromDocument(this.view.state.doc)
    this.hidden.value = JSON.stringify(moments)
    this.feedback = []
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
      decorations.push(Decoration.node(active.from, active.from + 1, { class: "description-active-moment", "aria-current": "true" }))
    }
    const invalid = invalidMomentIds(state.doc, Number(this.el?.dataset.duration ?? Infinity), this.originalStarts)
    const pending = momentDeletionKey.getState(state)
    if (pending) decorations.push(Decoration.node(pending.position, pending.position + 1, { class: "description-armed-moment" }))
    const cueEnds = subtitle
      ? new Map(this.playbackWindows.map(window => [window.id, window.end])) : null
    state.doc.descendants((node, position) => {
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
    let current = node
    const dom = document.createElement("span")
    dom.className = "description-moment"
    dom.contentEditable = "false"
    const button = document.createElement("button")
    button.type = "button"
    button.className = "description-time"
    const endButton = subtitle ? button.cloneNode(false) : null
    const refresh = () => {
      button.textContent = formatMoment(current.attrs.start)
      button.dataset.previewTime = current.attrs.start
      button.setAttribute("aria-label", `${subtitle ? this.el.dataset.startLabel : this.el.dataset.editTimeLabel} ${button.textContent}`)
      if (endButton) {
        const end = current.attrs.end ?? cueTiming?.end
        endButton.title = cueTiming?.pace || ""
        if (endButton.title) endButton.setAttribute("aria-description", endButton.title)
        else endButton.removeAttribute("aria-description")
        endButton.disabled = !Number.isFinite(end)
        endButton.textContent = endButton.disabled ? "…" : formatMoment(end)
        endButton.setAttribute("aria-label", `${this.el.dataset.endLabel} ${endButton.textContent}`)
      }
    }
    refresh()
    dom.appendChild(button)
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
      input.addEventListener("keydown", event => {
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
        refresh()
        return true
      },
    }
  },

  destroyed() {
    this.destroyedEditor = true
    this.form.removeEventListener("submit", this.beforeSubmit, true)
    this.form.removeEventListener("description:playhead", this.onPlayhead)
    this.addButton.removeEventListener("click", this.addMoment)
    this.view.destroy()
  },
}
