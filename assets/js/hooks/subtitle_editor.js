// Subtitle editor: playback, caption preview, caret keys and the timeline.
//
// The LiveView owns the cues. This hook reads them from the rendered rows
// (`data-start`, `data-end` and the textarea values), so the timeline and the
// caption follow whatever the server last rendered plus what is being typed.

const EDIT_DEBOUNCE = 250
const RESUME_AFTER_TYPING = 1200
const RATES = [1, 1.25, 1.5, 2, 0.75]
const MIN_CUE = 0.1
const MIN_SPAN = 4
const EDGE = 7
const TICKS = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

const clamp = (value, min, max) => Math.min(Math.max(value, min), max)
const round = (seconds) => Math.round(seconds * 1000) / 1000
const plain = (text) => text.replace(/<\/?[A-Za-z][^>]*>|<\d+:[\d:.]+>/g, "")

const clock = (seconds, tenths = true) => {
  const total = Math.max(Math.round(seconds * 10), 0)
  const rest = total % 600
  const base = `${Math.floor(total / 600)}:${String(Math.floor(rest / 10)).padStart(2, "0")}`
  return tenths ? `${base}.${rest % 10}` : base
}

export const SubtitleEditorHook = {
  mounted() {
    this.video = this.el.querySelector("#subtitle-player video")
    this.caption = this.el.querySelector("#subtitle-player [data-caption]")
    this.play = this.el.querySelector("[data-play]")
    this.clock = this.el.querySelector("[data-clock]")
    this.seekBar = this.el.querySelector("[data-seek]")
    this.progress = this.el.querySelector("[data-progress]")
    this.rate = this.el.querySelector("[data-rate-value]")
    this.strip = this.el.querySelector("[data-strip]")
    this.frame = this.el.querySelector("[data-window]")
    this.lane = this.el.querySelector("[data-lane]")
    this.ruler = this.el.querySelector("[data-ruler]")
    this.list = this.el.querySelector("#subtitle-cues")

    this.time = 0
    this.cues = []
    this.overrides = {}
    this.pending = new Map()
    this.span = null
    this.viewStart = 0
    this.follow = true
    this.activeId = null

    this.playhead = document.createElement("div")
    this.playhead.className = "pointer-events-none absolute inset-y-0 z-10 w-px bg-white/90"
    this.highlight = document.createElement("style")
    document.head.appendChild(this.highlight)

    this.listen(this.el, "keydown", (event) => this.onKeydown(event))
    this.listen(this.el, "input", (event) => this.onInput(event))
    this.listen(this.el, "focusin", (event) => this.onFocus(event))
    this.listen(this.el, "focusout", (event) => this.onBlur(event))
    this.listen(this.el, "mousedown", (event) => this.onMousedown(event), true)
    this.listen(this.el, "click", (event) => this.onClick(event))
    this.listen(document, "click", (event) => this.onLinkClick(event), true)
    this.listen(window, "beforeunload", (event) => {
      if (!this.dirty()) return
      event.preventDefault()
      event.returnValue = ""
    })
    this.listen(window, "resize", () => this.draw())

    this.listen(this.video, "timeupdate", () => this.tick())
    this.listen(this.video, "seeked", () => this.tick())
    this.listen(this.video, "play", () => this.onPlayState())
    this.listen(this.video, "pause", () => this.onPlayState())
    this.listen(this.video, "ended", () => this.onPlayState())
    this.listen(this.video, "error", () => this.loadSource())
    this.listen(this.video, "click", () => this.togglePlay())

    this.scrub(this.seekBar, (ratio) => this.seek(ratio * this.duration()))
    this.scrub(this.strip, (ratio) => this.seek(ratio * this.duration()))
    this.listen(this.lane, "pointerdown", (event) => this.onLaneDown(event))
    this.listen(this.lane, "pointermove", (event) => this.onLaneMove(event))
    this.listen(this.lane, "pointerup", (event) => this.onLaneUp(event))
    this.listen(this.lane, "pointercancel", (event) => this.onLaneUp(event, true))
    this.listen(this.lane, "wheel", (event) => this.onLaneWheel(event), { passive: false })

    // Rows change without this element changing, so watch them directly.
    this.observer = new MutationObserver((mutations) => {
      mutations.forEach(({ type, target }) => {
        if (type === "attributes" && target.dataset.cue) delete this.overrides[target.dataset.cue]
      })
      this.scheduleRefresh()
    })
    this.observer.observe(this.list, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-start", "data-end", "data-warn", "data-selected"],
    })

    this.handleEvent("subtitles:cue", (payload) => this.showCue(payload))
    this.handleEvent("subtitles:reset", () => this.scheduleRefresh())
    this.handleEvent("subtitles:download", ({ filename, body }) => {
      const link = document.createElement("a")
      link.href = URL.createObjectURL(new Blob([body], { type: "text/vtt" }))
      link.download = filename
      link.click()
      setTimeout(() => URL.revokeObjectURL(link.href), 1000)
    })

    this.sources = JSON.parse(this.el.querySelector("#subtitle-player").dataset.sources || "[]")
    this.loadSource()
    this.refresh()
  },

  updated() {
    this.scheduleRefresh()
  },

  destroyed() {
    this.listeners.forEach(([target, name, handler, options]) =>
      target.removeEventListener(name, handler, options)
    )
    this.observer.disconnect()
    this.highlight.remove()
    cancelAnimationFrame(this.frameRequest)
    cancelAnimationFrame(this.refreshRequest)
    clearTimeout(this.resumeTimer)
    this.pending.forEach((timer) => clearTimeout(timer))
    this.video.pause()
  },

  listen(target, name, handler, options) {
    this.listeners = this.listeners || []
    this.listeners.push([target, name, handler, options])
    target.addEventListener(name, handler, options)
  },

  dirty() {
    return this.el.dataset.dirty === "true" || this.pending.size > 0
  },

  duration() {
    const known = Number(this.el.dataset.duration)
    if (known > 0) return known
    if (Number.isFinite(this.video.duration) && this.video.duration > 0) return this.video.duration
    return Math.max(...this.cues.map((cue) => cue.end), 1)
  },

  // Playback

  loadSource() {
    const hls = this.video.canPlayType("application/vnd.apple.mpegurl")

    while (this.sources.length) {
      const source = this.sources.shift()
      if (/\.m3u8(\?|$)/.test(source) && !hls) continue
      this.video.src = source
      return
    }
  },

  togglePlay() {
    this.resume = false
    if (this.video.paused) {
      if (this.time >= this.duration() - 0.05) this.seek(0)
      this.follow = true
      this.video.play().catch(() => {})
    } else {
      this.video.pause()
    }
  },

  onPlayState() {
    const playing = !this.video.paused && !this.video.ended
    this.play.toggleAttribute("data-playing", playing)
    cancelAnimationFrame(this.frameRequest)

    if (playing) {
      const loop = () => {
        this.tick()
        this.frameRequest = requestAnimationFrame(loop)
      }
      loop()
    } else {
      this.tick()
    }
  },

  seek(seconds) {
    this.time = clamp(seconds, 0, this.duration())
    this.follow = true
    try {
      this.video.currentTime = this.time
    } catch (_error) {
      // Without a playable source the editor keeps its own clock.
    }
    this.paint()
  },

  tick() {
    if (this.video.readyState > 0 && !this.video.seeking) this.time = this.video.currentTime
    this.paint()
  },

  // Everything that follows the clock.
  paint() {
    const duration = this.duration()
    this.clock.textContent = clock(this.time)
    this.progress.style.width = `${clamp(this.time / duration, 0, 1) * 100}%`

    const active = this.cues.find((cue) => this.time >= cue.start && this.time < cue.end)
    const activeId = active ? active.id : null

    if (activeId !== this.activeId) {
      this.activeId = activeId
      this.highlight.textContent = activeId
        ? `#subtitle-cue-${CSS.escape(activeId)} [data-cue-dot]{opacity:1}`
        : ""

      const typing = this.list.contains(document.activeElement)
      if (active && !this.video.paused && !typing) this.reveal(active.row)
    }

    this.paintCaption(active)

    if (this.follow && !this.drag) {
      const ahead = this.time - this.viewStart

      if (ahead < 0 || ahead > this.span * 0.9) {
        const lead = this.span * (this.video.paused ? 0.4 : 0.1)
        const start = clamp(this.time - lead, 0, Math.max(duration - this.span, 0))

        if (Math.abs(start - this.viewStart) > 0.001) {
          this.viewStart = start
          this.draw()
          return
        }
      }
    }

    this.paintPlayhead()
  },

  paintCaption(active) {
    const text = active
      ? plain(active.text())
          .split("\n")
          .map((line) => line.trim())
          .filter(Boolean)
          .join("\n")
      : ""

    if (text === this.captionText) return
    this.captionText = text
    this.caption.replaceChildren()
    if (!text) return

    text.split("\n").forEach((content) => {
      const line = document.createElement("div")
      const box = document.createElement("span")
      box.className = "bg-black/75 px-2 py-0.5 box-decoration-clone"
      box.textContent = content
      line.appendChild(box)
      this.caption.appendChild(line)
    })
  },

  paintPlayhead() {
    const ratio = (this.time - this.viewStart) / this.span
    this.playhead.style.left = `${ratio * 100}%`
    this.playhead.style.display = ratio < 0 || ratio > 1 ? "none" : ""
  },

  // Cues

  scheduleRefresh() {
    cancelAnimationFrame(this.refreshRequest)
    this.refreshRequest = requestAnimationFrame(() => this.refresh())
  },

  refresh() {
    this.cues = [...this.list.querySelectorAll("[data-cue]")].map((row) => {
      const id = row.dataset.cue
      const field = row.querySelector("[data-cue-text]")
      const moved = this.overrides[id]

      return {
        id,
        row,
        field,
        start: moved ? moved.start : Number(row.dataset.start),
        end: moved ? moved.end : Number(row.dataset.end),
        warn: row.dataset.warn === "true",
        selected: row.dataset.selected === "true",
        text: () => field.value,
      }
    })

    if (!CSS.supports("field-sizing", "content")) this.cues.forEach((cue) => this.fit(cue.field))

    const duration = this.duration()
    if (this.span === null) this.span = Math.min(duration, 12)
    this.span = clamp(this.span, Math.min(MIN_SPAN, duration), duration)
    this.activeId = undefined
    this.captionText = undefined
    this.draw()
    this.paint()
  },

  fit(field) {
    field.style.height = "auto"
    field.style.height = `${field.scrollHeight}px`
  },

  cue(id) {
    return this.cues.find((cue) => cue.id === id)
  },

  fieldCue(field) {
    const row = field.closest("[data-cue]")
    return row && row.dataset.cue
  },

  reveal(row) {
    const box = this.list.getBoundingClientRect()
    const rect = row.getBoundingClientRect()

    if (rect.top < box.top + 8 || rect.bottom > box.bottom - 24) {
      const top = this.list.scrollTop + rect.top - box.top - box.height * 0.35
      this.list.scrollTo({ top, behavior: "smooth" })
    }
  },

  focusField(field, offset) {
    this.quiet = true
    field.focus({ preventScroll: true })
    this.quiet = false
    if (Number.isInteger(offset)) field.setSelectionRange(offset, offset)
    this.reveal(field.closest("[data-cue]"))
  },

  showCue({ id, text, offset, focus, seek }) {
    const row = this.list.querySelector(`#subtitle-cue-${CSS.escape(id)}`)
    if (!row) return

    const field = row.querySelector("[data-cue-text]")
    if (!this.pending.has(id) && field.value !== text) field.value = text

    if (focus) this.focusField(field, offset)
    else this.reveal(row)

    this.refresh()
    if (seek) this.seek(Number(row.dataset.start) + 0.001)
  },

  // Typing

  pushEdit(id, field) {
    clearTimeout(this.pending.get(id))
    this.pending.delete(id)
    this.pushEvent("edit", { id, text: field.value })
  },

  flush() {
    ;[...this.pending.keys()].forEach((id) => {
      const cue = this.cue(id)
      clearTimeout(this.pending.get(id))
      this.pending.delete(id)
      if (cue && cue.row.isConnected) this.pushEvent("edit", { id, text: cue.field.value })
    })
  },

  drop(id) {
    clearTimeout(this.pending.get(id))
    this.pending.delete(id)
  },

  onInput(event) {
    const field = event.target
    if (!field.matches("[data-cue-text]")) return

    const id = this.fieldCue(field)
    clearTimeout(this.pending.get(id))
    this.pending.set(
      id,
      setTimeout(() => this.pushEdit(id, field), EDIT_DEBOUNCE)
    )

    if (!CSS.supports("field-sizing", "content")) this.fit(field)
    this.captionText = undefined
    this.draw()
    this.paint()
    this.holdPlayback()
  },

  holdPlayback() {
    if (this.el.dataset.pauseWhileTyping !== "true") return

    if (!this.video.paused) {
      this.resume = true
      this.video.pause()
    }

    if (this.resume) {
      clearTimeout(this.resumeTimer)
      this.resumeTimer = setTimeout(() => {
        if (this.resume) this.video.play().catch(() => {})
        this.resume = false
      }, RESUME_AFTER_TYPING)
    }
  },

  onFocus(event) {
    const field = event.target
    if (!field.matches("[data-cue-text]")) return

    const cue = this.cue(this.fieldCue(field))
    if (!cue) return
    if (!cue.selected) this.pushEvent("select", { id: cue.id })
    if (!this.quiet && !(this.time >= cue.start && this.time < cue.end)) this.seek(cue.start + 0.001)
  },

  onBlur(event) {
    if (event.target.matches("[data-cue-text]")) this.flush()
  },

  onMousedown(event) {
    this.flush()

    if (event.target.closest("[data-keep-focus]")) {
      event.preventDefault()
      return
    }

    const row = event.target.closest("[data-cue]")
    if (row && !event.target.closest("button, textarea")) {
      event.preventDefault()
      const field = row.querySelector("[data-cue-text]")
      field.focus({ preventScroll: true })
      field.setSelectionRange(field.value.length, field.value.length)
    }
  },

  onClick(event) {
    if (event.target.closest("[data-play]")) return this.togglePlay()

    if (event.target.closest("[data-rate]")) {
      const next = RATES[(RATES.indexOf(this.video.playbackRate) + 1) % RATES.length]
      this.video.playbackRate = next
      this.rate.textContent = String(next)
      return
    }

    const zoom = event.target.closest("[data-zoom]")
    if (zoom) return this.zoom(zoom.dataset.zoom === "in" ? 1 / 1.6 : 1.6)

    if (event.target.closest("[data-action='split']")) this.splitSelected()
  },

  onKeydown(event) {
    if (event.isComposing) return

    const field = event.target
    const inCue = field.matches("[data-cue-text]")
    const inField = inCue || field.matches("input, textarea, select")
    const command = event.metaKey || event.ctrlKey
    const key = event.key.toLowerCase()

    if (command && !event.altKey && (key === "z" || key === "y") && (inCue || !inField)) {
      event.preventDefault()
      this.flush()
      if (inCue) field.blur()
      this.pushEvent(key === "y" || event.shiftKey ? "redo" : "undo", {})
      return
    }

    if (!inField && key === " " && !event.target.closest("button, a")) {
      event.preventDefault()
      this.togglePlay()
      return
    }

    if (!inCue) return

    const id = this.fieldCue(field)
    const { selectionStart: from, selectionEnd: to, value } = field
    const collapsed = from === to
    const index = this.cues.findIndex((cue) => cue.id === id)

    if (key === "enter" && !event.shiftKey && !command && !event.altKey) {
      event.preventDefault()
      const before = value.slice(0, from)
      const after = value.slice(to)

      if (before.trim() === "") return
      this.drop(id)

      if (after.trim() === "") {
        this.pushEvent("edit", { id, text: value })
        this.pushEvent("add", { id })
      } else {
        this.pushEvent("split", { id, before, after })
      }
    } else if (key === "backspace" && collapsed && from === 0 && index > 0) {
      event.preventDefault()
      this.flush()
      this.drop(id)
      this.pushEvent("merge", { id, direction: "previous", text: value })
    } else if (key === "delete" && collapsed && from === value.length && index < this.cues.length - 1) {
      event.preventDefault()
      this.flush()
      this.drop(id)
      this.pushEvent("merge", { id, direction: "next", text: value })
    } else if (key === "arrowup" && collapsed && from === 0 && index > 0) {
      event.preventDefault()
      const previous = this.cues[index - 1].field
      previous.focus({ preventScroll: true })
      previous.setSelectionRange(previous.value.length, previous.value.length)
      this.reveal(this.cues[index - 1].row)
    } else if (key === "arrowdown" && collapsed && from === value.length && index < this.cues.length - 1) {
      event.preventDefault()
      const next = this.cues[index + 1].field
      next.focus({ preventScroll: true })
      next.setSelectionRange(0, 0)
      this.reveal(this.cues[index + 1].row)
    } else if (key === "escape") {
      field.blur()
    }
  },

  // The split tile: at the caret when a line is being edited, otherwise at the
  // word nearest to the playhead (or the middle of the cue).
  splitSelected() {
    const cue = this.cues.find((candidate) => candidate.selected)
    if (!cue) return

    const value = cue.field.value
    let at = document.activeElement === cue.field ? cue.field.selectionStart : null

    if (at === null || value.slice(0, at).trim() === "" || value.slice(at).trim() === "") {
      const inside = this.time > cue.start && this.time < cue.end
      const ratio = inside ? (this.time - cue.start) / (cue.end - cue.start) : 0.5
      const target = Math.round(value.length * ratio)
      const breaks = [...value.matchAll(/\s+/g)].map((match) => match.index)
      if (!breaks.length) return
      at = breaks.reduce((best, index) =>
        Math.abs(index - target) < Math.abs(best - target) ? index : best
      )
    }

    this.drop(cue.id)
    this.pushEvent("split", { id: cue.id, before: value.slice(0, at), after: value.slice(at) })
  },

  // Leaving with unpublished changes goes through the page's own dialog.
  onLinkClick(event) {
    if (!this.dirty() || event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    const link = event.target.closest("a[data-phx-link]")
    if (!link || link.target === "_blank") return

    const url = new URL(link.href, window.location.href)
    if (url.origin !== window.location.origin) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.flush()
    this.pushEvent("leave", { to: url.pathname + url.search })
  },

  // Timeline

  scrub(target, apply) {
    const at = (event) => {
      const rect = target.getBoundingClientRect()
      apply(clamp((event.clientX - rect.left) / rect.width, 0, 1))
    }

    this.listen(target, "pointerdown", (event) => {
      if (event.button !== 0) return
      event.preventDefault()
      target.setPointerCapture(event.pointerId)
      target.dataset.scrubbing = "true"
      at(event)
    })
    this.listen(target, "pointermove", (event) => {
      if (target.dataset.scrubbing) at(event)
    })
    const stop = () => delete target.dataset.scrubbing
    this.listen(target, "pointerup", stop)
    this.listen(target, "pointercancel", stop)
  },

  zoom(factor) {
    const duration = this.duration()
    const centre = clamp(this.time, this.viewStart, this.viewStart + this.span)
    const ratio = (centre - this.viewStart) / this.span
    this.span = clamp(this.span * factor, Math.min(MIN_SPAN, duration), duration)
    this.viewStart = centre - this.span * ratio
    this.draw()
  },

  draw() {
    const duration = this.duration()
    this.viewStart = clamp(this.viewStart, 0, Math.max(duration - this.span, 0))
    const { viewStart, span } = this
    const x = (seconds) => ((seconds - viewStart) / span) * 100

    this.frame.style.left = `${(viewStart / duration) * 100}%`
    this.frame.style.width = `${Math.min(span / duration, 1) * 100}%`

    const blocks = this.cues
      .filter((cue) => cue.end > viewStart && cue.start < viewStart + span)
      .map((cue) => {
        const block = document.createElement("div")
        block.dataset.block = cue.id
        block.className =
          "absolute inset-y-0 flex items-center overflow-hidden whitespace-nowrap rounded-sm px-1.5 text-xs ring-1 ring-inset cursor-grab bg-stone-800 " +
          (cue.selected ? "z-[5] ring-blue-600 text-stone-300" : "ring-stone-900 text-stone-500")
        block.style.left = `${x(cue.start)}%`
        block.style.width = `${x(cue.end) - x(cue.start)}%`

        if (cue.selected) {
          ;["left-[3px]", "right-[3px]"].forEach((side) => {
            const grip = document.createElement("div")
            grip.className = `pointer-events-none absolute inset-y-2 w-px bg-stone-500 ${side}`
            block.appendChild(grip)
          })
        }

        if (cue.warn) {
          const led = document.createElement("div")
          led.className =
            "pointer-events-none mr-1.5 h-1.5 w-1.5 flex-none rounded-full bg-gradient-to-b from-amber-300 to-amber-500"
          block.appendChild(led)
        }

        const label = document.createElement("div")
        label.className = "pointer-events-none truncate" + (cue.selected ? " pl-1" : "")
        label.textContent = plain(cue.text()).replace(/\s+/g, " ")
        block.appendChild(label)
        return block
      })

    this.lane.replaceChildren(...blocks, this.playhead)

    const step = TICKS.find((tick) => span / tick <= 6) || 1200
    const labels = []

    for (let tick = Math.ceil(viewStart / step) * step; tick <= viewStart + span; tick += step) {
      const position = x(tick)
      if (position < 5 || position > 95) continue
      const label = document.createElement("div")
      label.className =
        "absolute top-0 -translate-x-1/2 font-mono text-[0.65rem] text-stone-600 tabular-nums"
      label.style.left = `${position}%`
      label.textContent = clock(tick, step < 1)
      labels.push(label)
    }

    this.ruler.replaceChildren(...labels)
    this.paintPlayhead()
  },

  laneTime(event) {
    const rect = this.lane.getBoundingClientRect()
    return this.viewStart + ((event.clientX - rect.left) / rect.width) * this.span
  },

  onLaneDown(event) {
    if (event.button !== 0) return
    event.preventDefault()
    this.flush()
    this.lane.setPointerCapture(event.pointerId)

    const block = event.target.closest("[data-block]")
    const cue = block && this.cue(block.dataset.block)

    if (!cue) {
      this.drag = { mode: "seek" }
      this.seek(this.laneTime(event))
      return
    }

    const rect = block.getBoundingClientRect()
    const edges = cue.selected && rect.width > EDGE * 3
    const mode =
      edges && event.clientX - rect.left < EDGE
        ? "start"
        : edges && rect.right - event.clientX < EDGE
          ? "end"
          : "move"

    const index = this.cues.indexOf(cue)
    const previous = this.cues[index - 1]
    const next = this.cues[index + 1]

    this.drag = {
      mode,
      cue,
      from: this.laneTime(event),
      x: event.clientX,
      start: cue.start,
      end: cue.end,
      min: previous ? Math.min(previous.end, cue.start) : 0,
      max: next ? Math.max(next.start, cue.end) : this.duration(),
      moved: false,
    }
  },

  onLaneMove(event) {
    const drag = this.drag
    if (!drag) return
    if (drag.mode === "seek") return this.seek(this.laneTime(event))
    if (!drag.moved && Math.abs(event.clientX - drag.x) < 3) return

    drag.moved = true
    const delta = this.laneTime(event) - drag.from
    const length = drag.end - drag.start
    const { cue } = drag

    if (drag.mode === "move") {
      cue.start = round(clamp(drag.start + delta, drag.min, Math.max(drag.max - length, drag.min)))
      cue.end = round(cue.start + length)
    } else if (drag.mode === "start") {
      cue.start = round(clamp(drag.start + delta, drag.min, drag.end - MIN_CUE))
    } else {
      cue.end = round(clamp(drag.end + delta, drag.start + MIN_CUE, drag.max))
    }

    this.overrides[cue.id] = { start: cue.start, end: cue.end }
    this.draw()
    this.paint()
  },

  onLaneUp(event, cancelled = false) {
    const drag = this.drag
    this.drag = null
    if (!drag || drag.mode === "seek") return

    const { cue } = drag

    if (cancelled) {
      delete this.overrides[cue.id]
      this.refresh()
    } else if (drag.moved) {
      this.pushEvent("retime", { id: cue.id, start: cue.start, end: cue.end }, () => {
        delete this.overrides[cue.id]
        this.scheduleRefresh()
      })
    } else {
      this.focusField(cue.field, cue.field.value.length)
      this.seek(cue.start + 0.001)
    }
  },

  onLaneWheel(event) {
    event.preventDefault()

    if (event.ctrlKey || event.metaKey) {
      this.zoom(event.deltaY > 0 ? 1.25 : 0.8)
      return
    }

    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY
    this.follow = false
    this.viewStart += (delta / this.lane.clientWidth) * this.span
    this.draw()
  },
}
