export function previewSource(video, preferred, fallback) {
  if (!preferred) return fallback
  const playlist = new URL(preferred, document.baseURI).pathname.endsWith(".m3u8")
  return !playlist || video.canPlayType("application/vnd.apple.mpegurl") ? preferred : fallback
}

export function previewTime(seconds, duration) {
  const upper = Number.isFinite(duration) ? Math.max(0, duration - 0.001) : Infinity
  return Math.min(Math.max(0, seconds), upper)
}

export const TextEditorPreviewHook = {
  mounted() {
    this.listeners = []
    this.preview = this.el.querySelector("[data-preview-template]").content.firstElementChild.cloneNode(true)
    this.preview.id = `${this.el.id}-frame-preview`
    document.body.appendChild(this.preview)
    this.video = this.preview.querySelector("video")
    this.status = this.preview.querySelector("[data-preview-status]")
    this.loadingText = this.status.textContent
    this.scrollArea = this.el.querySelector("[data-editor-scroll]")

    this.listen(this.el, "pointerover", event => this.openTarget(event.target))
    this.listen(this.el, "focusin", event => this.openTarget(event.target))
    this.listen(this.el, "click", event => this.openTarget(event.target))
    this.listen(this.el, "pointerout", event => {
      if (this.target?.contains(event.target) && !this.target.contains(event.relatedTarget)) this.hide()
    })
    this.listen(this.el, "focusout", () => this.hide())
    this.listen(this.el, "input", event => {
      if (event.target.matches("textarea")) this.resizeTextarea(event.target)
    })
    this.listen(this.scrollArea, "scroll", () => this.hide())
    this.listen(window, "resize", () => { this.hide(); this.resizeTextareas() })
    this.listen(this.el, "keydown", event => { if (event.key === "Escape") this.hide() })
    this.listen(this.video, "loadedmetadata", () => this.seek())
    this.listen(this.video, "seeked", () => this.revealFrame())
    this.listen(this.video, "loadeddata", () => this.revealFrame())
    this.listen(this.video, "error", () => this.fallback())
    this.resizeTextareas()
    this.resizeFrame = requestAnimationFrame(() => this.resizeTextareas())
  },

  updated() {
    this.hide()
    this.resizeTextareas()
  },

  listen(target, event, handler) {
    target.addEventListener(event, handler)
    this.listeners.push(() => target.removeEventListener(event, handler))
  },

  resizeTextarea(textarea) {
    const scrollTop = this.scrollArea.scrollTop
    textarea.style.height = "auto"
    textarea.style.height = `${textarea.scrollHeight + 2}px`
    this.scrollArea.scrollTop = scrollTop
  },

  resizeTextareas() {
    this.el.querySelectorAll("textarea").forEach(textarea => this.resizeTextarea(textarea))
  },

  openTarget(element) {
    const target = element.closest("[data-preview-time]")
    if (!target || target.disabled || target === this.target) return
    this.hide()
    this.target = target
    this.timer = setTimeout(() => this.show(target), 120)
  },

  show(target) {
    const seconds = Number(target.dataset.previewTime)
    if (!target.isConnected || !Number.isFinite(seconds)) return
    this.seconds = seconds
    this.preview.hidden = false
    this.preview.querySelector("[data-preview-label]").textContent = target.textContent.trim()
    target.setAttribute("aria-describedby", this.preview.id)
    this.video.classList.add("opacity-0")
    this.status.hidden = false
    this.status.textContent = this.loadingText

    const rect = target.getBoundingClientRect()
    const width = this.preview.offsetWidth
    const height = this.preview.offsetHeight
    const left = rect.right + 12 + width <= window.innerWidth - 8
      ? rect.right + 12 : Math.max(8, rect.left - width - 12)
    this.preview.style.left = `${left}px`
    this.preview.style.top = `${Math.max(8, Math.min(rect.top - height / 2, window.innerHeight - height - 8))}px`

    const source = previewSource(this.video, this.el.dataset.previewSrc, this.el.dataset.fallbackSrc)
    if (!source) return this.unavailable()
    const nextSource = source === this.failedSource ? this.el.dataset.fallbackSrc : source
    if (nextSource !== this.currentSource) {
      this.currentSource = nextSource
      this.video.muted = true
      this.video.preload = "metadata"
      this.video.src = nextSource
      this.video.load()
    } else {
      this.seek()
    }
  },

  seek() {
    if (this.preview.hidden || this.video.readyState < 1) return
    this.video.currentTime = previewTime(this.seconds, this.video.duration)
    this.revealFrame()
  },

  revealFrame() {
    if (this.video.readyState >= 2 && !this.video.seeking &&
        Math.abs(this.video.currentTime - previewTime(this.seconds, this.video.duration)) < 0.1) {
      this.video.classList.remove("opacity-0")
      this.status.hidden = true
    }
  },

  fallback() {
    const fallback = this.el.dataset.fallbackSrc
    if (fallback && this.currentSource !== fallback) {
      this.failedSource = this.currentSource
      this.currentSource = fallback
      this.video.src = fallback
      this.video.load()
    } else {
      this.unavailable()
    }
  },

  unavailable() {
    this.video.classList.add("opacity-0")
    this.status.hidden = false
    this.status.textContent = this.status.dataset.unavailable
  },

  hide() {
    clearTimeout(this.timer)
    this.target?.removeAttribute("aria-describedby")
    this.target = null
    this.preview.hidden = true
  },

  destroyed() {
    this.hide()
    cancelAnimationFrame(this.resizeFrame)
    this.listeners.forEach(remove => remove())
    this.video.removeAttribute("src")
    this.video.load()
    this.preview.remove()
  },
}
