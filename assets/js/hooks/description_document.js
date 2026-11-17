import { Schema } from "prosemirror-model"
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
      attrs: { id: {}, start: {} },
      leafText: node => `[${formatMoment(node.attrs.start)}]`,
      toDOM: node => ["span", { "data-moment": node.attrs.id, "data-start": node.attrs.start }, `[${formatMoment(node.attrs.start)}]`],
      parseDOM: [{ tag: "span[data-moment]", getAttrs: el => ({ id: el.dataset.moment, start: Number(el.dataset.start) }) }],
    },
  },
})

export function replaceWithMoment(state, from, to, time, id) {
  const node = descriptionSchema.nodes.moment.create({ id, start: time })
  const transaction = state.tr.delete(from, to)
  let position = from
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

export function documentFromMoments(moments) {
  const paragraphs = []
  for (const moment of moments) {
    const lines = moment.text.split("\n")
    lines.forEach((line, index) => {
      const content = []
      if (index === 0 && moment.start != null) content.push(descriptionSchema.nodes.moment.create({ id: moment.id, start: moment.start }))
      if (line) content.push(descriptionSchema.text(line))
      else if (content.length) content.push(descriptionSchema.text(" "))
      paragraphs.push(descriptionSchema.nodes.paragraph.create(null, content))
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
  let active = -1
  anchors.forEach((anchor, index) => {
    const window = windows.find(window => window.id === anchor.id)
    if (window && window.start <= time && time < window.end && (active < 0 || anchor.start >= anchors[active].start)) active = index
  })
  return active < 0 ? null : { ...anchors[active], to: anchors[active + 1]?.from ?? doc.content.size }
}

export function invalidMomentIds(doc, duration = Infinity) {
  const anchors = []
  doc.descendants(node => {
    if (node.type.name === "moment") anchors.push(node.attrs)
  })
  return new Set(anchors.filter((anchor, index) =>
    !Number.isFinite(anchor.start) || anchor.start < 0 || anchor.start >= duration ||
    (index > 0 && anchor.start <= anchors[index - 1].start) ||
    (index + 1 < anchors.length && anchor.start >= anchors[index + 1].start)
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
    this.view = new EditorView(this.el, {
      state: EditorState.create({
        doc: documentFromMoments(JSON.parse(this.el.dataset.document)),
        plugins: [history(), keymap({ "Backspace": backspaceMoment, "Mod-z": undo, "Shift-Mod-z": redo, "Mod-y": redo }), keymap(baseKeymap), inputRules({ rules: [typedMoment] }), uniqueMoments(), momentDeletionPlugin(), feedbackPlugin],
      }),
      attributes: { class: "description-prose", role: "textbox", "aria-multiline": "true", "aria-label": this.el.dataset.label },
      nodeViews: { moment: (node, view, getPos) => this.momentView(node, view, getPos) },
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
        Math.min(time, Number(this.el.dataset.duration) - 0.001), crypto.randomUUID()).scrollIntoView())
    }
    this.addButton.addEventListener("click", this.addMoment)
    this.beforeSubmit = () => { this.hidden.value = JSON.stringify(momentsFromDocument(this.view.state.doc).moments) }
    this.form.addEventListener("submit", this.beforeSubmit, true)
    this.onPlayhead = event => {
      const time = event.detail.time
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
    const decorations = this.feedback.flatMap(group => {
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
    const invalid = invalidMomentIds(state.doc, Number(this.el?.dataset.duration ?? Infinity))
    const pending = momentDeletionKey.getState(state)
    if (pending) decorations.push(Decoration.node(pending.position, pending.position + 1, { class: "description-armed-moment" }))
    state.doc.descendants((node, position) => {
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

  momentView(node, view, getPos) {
    let current = node
    const dom = document.createElement("span")
    dom.className = "description-moment"
    dom.contentEditable = "false"
    const button = document.createElement("button")
    button.type = "button"
    button.className = "description-time"
    const refresh = () => {
      button.textContent = formatMoment(current.attrs.start)
      button.dataset.previewTime = current.attrs.start
      button.setAttribute("aria-label", `${this.el.dataset.editTimeLabel} ${button.textContent}`)
    }
    refresh()
    dom.appendChild(button)
    button.addEventListener("click", () => {
      if (dom.querySelector("input")) return
      const input = document.createElement("input")
      input.type = "text"
      input.value = formatMoment(current.attrs.start)
      input.className = "description-time-input"
      input.setAttribute("aria-label", this.el.dataset.editTimeLabel)
      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "description-time-remove"
      remove.textContent = "×"
      remove.setAttribute("aria-label", this.el.dataset.removeTimeLabel)
      button.hidden = true
      dom.append(input, remove)
      const close = () => { input.remove(); remove.remove(); button.hidden = false }
      const commit = () => {
        const time = parseMoment(input.value)
        if (time == null || time >= Number(this.el.dataset.duration)) { input.setAttribute("aria-invalid", "true"); return }
        view.dispatch(view.state.tr.setNodeMarkup(getPos(), null, { ...current.attrs, start: time }))
        close()
        view.focus()
      }
      input.addEventListener("keydown", event => {
        if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); commit() }
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); view.focus() }
      })
      input.addEventListener("blur", event => { if (event.relatedTarget !== remove) commit() })
      remove.addEventListener("click", () => {
        view.dispatch(view.state.tr.delete(getPos(), getPos() + 1))
        view.focus()
      })
      input.focus()
      input.select()
    })
    return {
      dom,
      stopEvent: () => true,
      ignoreMutation: () => true,
      update(updated) { if (updated.type !== current.type) return false; current = updated; refresh(); return true },
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
