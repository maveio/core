// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "./setup"
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { hooks as colocatedHooks } from "phoenix-colocated/mave_core"
import topbar from "../vendor/topbar"
import "@lottiefiles/lottie-player"
import { ChartHook } from "./hooks/chart"
import { cdn } from "./upload"

let selectedEmbed = null

const PreserveScrollHook = {
  beforeUpdate() {
    this.savedScrollTop = this.el.scrollTop
    this.savedScrollLeft = this.el.scrollLeft
  },

  updated() {
    this.el.scrollTop = this.savedScrollTop
    this.el.scrollLeft = this.savedScrollLeft
  },
}

const ContentEditableHook = {
  mounted() {
    this.titleElement = this.el.querySelector("[data-title]")
    this.input = this.el.querySelector("input")

    if (!this.titleElement || !this.input) {
      return
    }

    this.titleElement.addEventListener("focus", this.showText.bind(this))
    this.titleElement.addEventListener("keyup", this.keyup.bind(this))
    this.el.addEventListener("focusout", this.save.bind(this))
  },

  showText() {
    const title = this.titleElement.getAttribute("data-title") || ""
    this.titleElement.innerText = title
  },

  keyup(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.titleElement.innerText = this.titleElement.innerText.replaceAll("\n", "")
      this.titleElement.blur()
    }
  },

  save() {
    const title = this.titleElement.innerText.trim()

    if (title.length > 49) {
      this.titleElement.innerText = `${title.slice(0, 49)}...`
    } else {
      this.titleElement.innerText = title
    }

    if (this.input.value === title) {
      return
    }

    this.input.value = title
    this.input.dispatchEvent(new Event("input", { bubbles: true }))
  },
}

const UploadBridgeHook = {
  mounted() {
    this.upload = this.el.querySelector("mave-upload")
    this.progressBar = this.el.querySelector("[data-role='progress-bar']")
    this.progressValue = this.el.querySelector("[data-role='progress-value']")
    this.errorTitle = this.el.querySelector("[data-role='error-title']")
    this.errorMessage = this.el.querySelector("[data-role='error-message']")
    this.errorFilename = this.el.querySelector("[data-role='error-filename']")
    this.completed = false

    if (!this.upload) {
      return
    }

    this.handleStateChange = (event) => {
      const { progress = 0, error } = event.detail || {}

      if (this.progressBar) {
        this.progressBar.style.width = `${progress}%`
      }

      if (this.progressValue) {
        this.progressValue.textContent = `${progress}%`
      }

      if (error) {
        this.applyError(error)
      }
    }

    this.handleCompleted = (event) => {
      if (this.completed) {
        return
      }

      this.completed = true

      if (this.progressBar) {
        this.progressBar.style.width = "100%"
      }

      if (this.progressValue) {
        this.progressValue.textContent = "100%"
      }

      this.pushEvent("upload_completed", event.detail || {})
    }

    this.handlePlayableRendition = (event) => {
      const rendition = event.detail || {}
      const playableMp4 =
        rendition.type === "video" &&
        rendition.container === "mp4" &&
        rendition.codec === "h264"
      const playableHls =
        rendition.type === "video" && rendition.container === "hls"

      if (playableMp4 || playableHls) {
        this.handleCompleted(event)
      }
    }

    this.handlePlayable = (event) => {
      this.handleCompleted(event)
    }

    this.handleUploadError = (event) => {
      this.applyError(event.detail || {})
    }

    this.upload.addEventListener("statechange", this.handleStateChange)
    this.upload.addEventListener("completed", this.handleCompleted)
    this.upload.addEventListener("playable", this.handlePlayable)
    this.upload.addEventListener("rendition", this.handlePlayableRendition)
    this.upload.addEventListener("error", this.handleUploadError)
    this.upload.addEventListener("failed", this.handleUploadError)
    this.upload.addEventListener("invalid", this.handleUploadError)
  },

  destroyed() {
    if (!this.upload) {
      return
    }

    this.upload.removeEventListener("statechange", this.handleStateChange)
    this.upload.removeEventListener("completed", this.handleCompleted)
    this.upload.removeEventListener("playable", this.handlePlayable)
    this.upload.removeEventListener("rendition", this.handlePlayableRendition)
    this.upload.removeEventListener("error", this.handleUploadError)
    this.upload.removeEventListener("failed", this.handleUploadError)
    this.upload.removeEventListener("invalid", this.handleUploadError)
  },

  applyError(detail) {
    const reason = detail.reason || detail.message || "upload failed"
    const message = detail.message || "Please choose a supported media file."
    const fileName = detail.file?.name || ""

    if (this.errorTitle) {
      this.errorTitle.textContent = reason
    }

    if (this.errorMessage) {
      this.errorMessage.textContent = message
    }

    if (this.errorFilename) {
      this.errorFilename.textContent = fileName
    }
  },
}

const ComponentLoaderHook = {
  mounted() {
    this.load()
  },

  updated() {
    this.load()
  },

  async load() {
    const configSrc = this.el.dataset.componentConfigSrc
    const src = this.el.dataset.componentSrc
    const config = this.el.dataset.componentConfig

    if (!src || !configSrc) {
      return
    }

    window.__maveComponentImports = window.__maveComponentImports || {}
    window.__maveComponentConfigImports = window.__maveComponentConfigImports || {}

    let parsedConfig = null
    if (config) {
      try {
        parsedConfig = JSON.parse(config)
      } catch (error) {
        console.error("Failed to parse mave components config", error)
        return
      }
    }

    if (!window.__maveComponentConfigImports[configSrc]) {
      window.__maveComponentConfigImports[configSrc] = import(configSrc).catch((error) => {
        delete window.__maveComponentConfigImports[configSrc]
        throw error
      })
    }

    try {
      const configModule = await window.__maveComponentConfigImports[configSrc]
      if (parsedConfig && typeof configModule.configureMave === "function") {
        configModule.configureMave(parsedConfig)
      } else if (parsedConfig && typeof configModule.setConfig === "function") {
        configModule.setConfig(parsedConfig)
      }

      if (!window.__maveComponentImports[src]) {
        window.__maveComponentImports[src] = import(src).catch((error) => {
          delete window.__maveComponentImports[src]
          throw error
        })
      }

      await window.__maveComponentImports[src]
      this.applyPlaybackSession()
    } catch (error) {
      console.error("Failed to load mave components bundle", error)
    }
  },

  destroyed() {
    clearTimeout(this.playbackRenewal)
    this.playbackDestroyed = true
  },

  applyPlaybackSession() {
    const key = `${this.el.dataset.playbackEmbed}:${this.el.dataset.playbackStatus}`
    if (!this.el.dataset.playbackEmbed || this.playbackDestroyed) return

    const apply = ({ session, embed }) => {
      document.querySelectorAll("mave-player, mave-clip, mave-audio").forEach((element) => {
        if (element.embed === embed) element.token = session?.token || ""
      })
    }
    if (this.playbackKey === key && this.playbackData &&
        (!this.playbackData.session || this.playbackData.session.expires_at * 1000 > Date.now() + 60000)) {
      apply(this.playbackData)
      return
    }
    if (this.playbackPending) return
    this.playbackPending = true
    this.pushEvent("playback_session", {}, (data) => {
      this.playbackPending = false
      if (this.playbackDestroyed) return
      if (key !== `${this.el.dataset.playbackEmbed}:${this.el.dataset.playbackStatus}`) {
        this.applyPlaybackSession()
        return
      }
      this.playbackKey = key
      this.playbackData = data
      apply(data)
      clearTimeout(this.playbackRenewal)
      if (data.session) {
        this.playbackRenewal = setTimeout(() => this.applyPlaybackSession(),
          Math.max(1000, data.session.expires_at * 1000 - Date.now() - 60000))
      }
    })
  },
}

const FolderDropHook = {
  mounted() {
    this.classes = ["border-transparent", "rounded-xl", "ring-blue-200"]

    this.el.addEventListener("dragover", this.dragOver.bind(this))
    this.el.addEventListener("dragleave", this.dragLeave.bind(this))
    this.el.addEventListener("drop", this.drop.bind(this))
    this.el.addEventListener("dragstart", this.dragStart.bind(this))
    this.el.addEventListener("dragend", this.dragEnd.bind(this))
  },

  dragOver(event) {
    event.preventDefault()

    if (selectedEmbed && selectedEmbed !== this.el.dataset.embedId) {
      this.el.classList.add(...this.classes)
    }
  },

  dragLeave() {
    this.el.classList.remove(...this.classes)
  },

  drop(event) {
    event.preventDefault()
    this.el.classList.remove(...this.classes)

    if (!selectedEmbed || selectedEmbed === this.el.dataset.embedId) {
      return
    }

    this.pushEvent("drop_embed", {
      id: selectedEmbed,
      to: this.el.dataset.targetFolderId,
    })
  },

  dragStart() {
    selectedEmbed = this.el.dataset.embedId
  },

  dragEnd() {
    selectedEmbed = null
    document.querySelectorAll("._folder").forEach((element) => {
      element.classList.remove("border-transparent", "rounded-xl", "ring-blue-200")
    })
  },
}

const BreadcrumbDropHook = {
  mounted() {
    this.classes = ["bg-blue-50", "ring-blue-200"]

    this.el.addEventListener("dragover", this.dragOver.bind(this))
    this.el.addEventListener("dragleave", this.dragLeave.bind(this))
    this.el.addEventListener("drop", this.drop.bind(this))
  },

  dragOver(event) {
    event.preventDefault()
    this.el.classList.add(...this.classes)
  },

  dragLeave() {
    this.el.classList.remove(...this.classes)
  },

  drop(event) {
    event.preventDefault()
    this.el.classList.remove(...this.classes)

    if (!selectedEmbed) {
      return
    }

    this.pushEvent("drop_embed", {
      id: selectedEmbed,
      to: this.el.dataset.dropTargetId || "",
    })
  },
}

const DraggableEmbedHook = {
  mounted() {
    this.el.addEventListener("dragstart", this.dragStart.bind(this))
    this.el.addEventListener("dragend", this.dragEnd.bind(this))
  },

  dragStart() {
    selectedEmbed = this.el.dataset.embedId
  },

  dragEnd() {
    selectedEmbed = null
    document.querySelectorAll("._folder").forEach((element) => {
      element.classList.remove("border-transparent", "rounded-xl", "ring-blue-200")
    })
  },
}

const ThumbnailPreviewHook = {
  mounted() {
    this.scrubbing = false
    this.offset = 0
    this.handleWindowMouseUp = this.endScrub.bind(this)

    this.bindElements()
    this.bindEvents()
    this.loadVideoSource()
    this.syncFromInputs()
  },

  updated() {
    this.bindElements()
    this.loadVideoSource()

    if (!this.scrubbing) {
      this.syncFromInputs()
    }
  },

  destroyed() {
    window.removeEventListener("mouseup", this.handleWindowMouseUp)
  },

  bindElements() {
    this.video = this.el.querySelector("video")
    this.videoContainer = this.el.querySelector("#video_container")
    this.scrubArea = this.el.querySelector("#scrub_area")
    this.hourInput = document.querySelector('input[name="settings[poster_time_hour]"]')
    this.minuteInput = document.querySelector('input[name="settings[poster_time_minute]"]')
    this.secondInput = document.querySelector('input[name="settings[poster_time_second]"]')
  },

  bindEvents() {
    if (this.eventsBound || !this.scrubArea || !this.videoContainer) {
      return
    }

    this.eventsBound = true

    this.scrubArea.addEventListener("mousedown", (event) => {
      this.scrubStart(event)
    })

    this.scrubArea.addEventListener("mousemove", (event) => {
      this.scrubMove(event)
    })

    this.scrubArea.addEventListener("click", (event) => {
      if (event.target === this.videoContainer || this.videoContainer.contains(event.target)) {
        return
      }

      this.seekToPointer(event)
      this.pushCurrentTime()
    })

    window.addEventListener("mouseup", this.handleWindowMouseUp)

    ;[this.hourInput, this.minuteInput, this.secondInput].forEach((input) => {
      if (!input || input.dataset.thumbnailBound === "true") {
        return
      }

      input.dataset.thumbnailBound = "true"
      input.addEventListener("input", () => this.syncFromInputs())
      input.addEventListener("change", () => this.syncFromInputs())
    })
  },

  loadVideoSource() {
    if (!this.video) {
      return
    }

    const preferredSrc = this.el.dataset.previewSrc || ""
    const fallbackSrc = this.el.dataset.fallbackSrc || ""
    const nextSrc = this.selectPlayableSource(preferredSrc, fallbackSrc)

    if (!nextSrc || this.currentSource === nextSrc) {
      return
    }

    this.currentSource = nextSrc
    this.video.preload = "metadata"
    this.video.src = nextSrc
    this.video.load()
    this.video.addEventListener(
      "loadedmetadata",
      () => {
        this.syncFromInputs()
      },
      { once: true },
    )
  },

  selectPlayableSource(preferredSrc, fallbackSrc) {
    if (preferredSrc && !preferredSrc.endsWith(".m3u8")) {
      return preferredSrc
    }

    if (preferredSrc && this.video && this.video.canPlayType("application/vnd.apple.mpegurl")) {
      return preferredSrc
    }

    return fallbackSrc || preferredSrc
  },

  syncFromInputs() {
    if (!this.video) {
      return
    }

    const seconds = this.readInputSeconds()

    if (Number.isNaN(this.video.duration)) {
      this.video.addEventListener(
        "loadedmetadata",
        () => {
          this.applyCurrentTime(seconds)
        },
        { once: true },
      )

      return
    }

    this.applyCurrentTime(seconds)
    this.writeInputs(this.video.currentTime || seconds)
  },

  readInputSeconds() {
    const hours = this.parseNumber(this.hourInput?.value)
    const minutes = this.parseNumber(this.minuteInput?.value)
    const seconds = this.parseNumber(this.secondInput?.value)

    return Math.max(hours * 3600 + minutes * 60 + seconds, 0)
  },

  applyCurrentTime(seconds) {
    if (!this.video) {
      return
    }

    const duration = Number.isFinite(this.video.duration) ? this.video.duration : 0
    const clamped = duration > 0 ? Math.min(seconds, duration) : seconds

    this.video.currentTime = clamped
    this.positionHandle(clamped)
  },

  scrubStart(event) {
    this.scrubbing = true

    const currentPosition = this.currentHandleLeft()
    const areaRect = this.scrubArea.getBoundingClientRect()
    const pointerX = (event.clientX || event.pageX) - areaRect.left

    this.offset = pointerX - currentPosition
  },

  scrubMove(event) {
    if (!this.scrubbing) {
      return
    }

    this.seekToPointer(event, this.offset)
  },

  seekToPointer(event, offset = this.handleWidth() / 2) {
    if (!this.video || !this.scrubArea || !this.videoContainer) {
      return
    }

    const areaRect = this.scrubArea.getBoundingClientRect()
    const pointerX = (event.clientX || event.pageX) - areaRect.left
    const availableWidth = Math.max(areaRect.width - this.handleWidth(), 0)
    const left = this.clamp(pointerX - offset, 0, availableWidth)
    const ratio = availableWidth > 0 ? left / availableWidth : 0
    const duration = Number.isFinite(this.video.duration) ? this.video.duration : 0
    const seconds = ratio * duration

    this.video.currentTime = seconds
    this.positionHandle(seconds)
    this.writeInputs(seconds)
  },

  positionHandle(seconds) {
    if (!this.videoContainer || !this.scrubArea) {
      return
    }

    const duration = Number.isFinite(this.video.duration) && this.video.duration > 0 ? this.video.duration : 0
    const availableWidth = Math.max(this.scrubArea.clientWidth - this.handleWidth(), 0)
    const ratio = duration > 0 ? seconds / duration : 0
    const left = availableWidth * ratio

    this.videoContainer.style.left = `${left}px`
  },

  writeInputs(seconds) {
    if (!this.hourInput || !this.minuteInput || !this.secondInput) {
      return
    }

    const safe = Math.max(seconds, 0)
    const hours = Math.floor(safe / 3600)
    const minutes = Math.floor((safe % 3600) / 60)
    const secondsPart = Math.round((safe % 60) * 100) / 100

    this.hourInput.value = String(hours)
    this.minuteInput.value = String(minutes)
    this.secondInput.value = String(secondsPart)
  },

  pushCurrentTime() {
    if (!this.secondInput) {
      return
    }

    this.secondInput.dispatchEvent(new Event("input", { bubbles: true }))
    this.secondInput.dispatchEvent(new Event("change", { bubbles: true }))
  },

  currentHandleLeft() {
    if (!this.videoContainer) {
      return 0
    }

    const left = parseFloat(this.videoContainer.style.left || "0")
    return Number.isFinite(left) ? left : 0
  },

  handleWidth() {
    return this.videoContainer ? this.videoContainer.getBoundingClientRect().width : 0
  },

  parseNumber(value) {
    const parsed = parseFloat(value || "0")
    return Number.isFinite(parsed) ? parsed : 0
  },

  clamp(value, min, max) {
    return Math.min(Math.max(value, min), max)
  },

  endScrub() {
    if (!this.scrubbing) {
      return
    }

    this.scrubbing = false
    this.offset = 0
    this.pushCurrentTime()
  },
}

const AutoOpenFilePickerHook = {
  mounted() {
    this.openIfNeeded()
  },

  updated() {
    this.openIfNeeded()
  },

  openIfNeeded() {
    const pickerRef = this.el.dataset.pickerRef || ""

    if (!pickerRef || this.lastOpenedRef === pickerRef) {
      return
    }

    const input = this.el.querySelector("input[type='file']")

    if (!input) {
      return
    }

    this.lastOpenedRef = pickerRef

    window.requestAnimationFrame(() => {
      if (typeof input.showPicker === "function") {
        input.showPicker()
      } else {
        input.click()
      }
    })
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    ...colocatedHooks,
    chart: ChartHook,
    content_editable: ContentEditableHook,
    upload_bridge: UploadBridgeHook,
    component_loader: ComponentLoaderHook,
    folder: FolderDropHook,
    breadcrumb: BreadcrumbDropHook,
    draggable: DraggableEmbedHook,
    thumbnail_preview: ThumbnailPreviewHook,
    auto_open_file_picker: AutoOpenFilePickerHook,
    preserve_scroll: PreserveScrollHook,
  },
  uploaders: { cdn },
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Clipboard copy handler for copyable_field component
window.addEventListener('mave:clipcopy', (event) => {
  if ('clipboard' in navigator) {
    const text = event.target.textContent
    navigator.clipboard.writeText(text)
  } else {
    alert('Sorry, your browser does not support clipboard copy.')
  }
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
