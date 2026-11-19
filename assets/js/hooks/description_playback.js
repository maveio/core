export function findEditorPlayer(embed, root = document) {
  return [...root.querySelectorAll("mave-player, mave-clip, mave-audio")]
    .find(player => player.getAttribute("embed") === embed)
}

export function findAudioMenu(root) {
  if (!root) return null
  const menu = root.querySelector("mave-audio-track-menu")
  if (menu) return menu
  for (const element of root.querySelectorAll("*")) {
    if (element.shadowRoot) {
      const nested = findAudioMenu(element.shadowRoot)
      if (nested) return nested
    }
  }
  return null
}

export function descriptionTrack(menu, label, language) {
  const matches = (menu?.tracks || []).filter(track =>
    track.label === label && (!track.language || !language || track.language.toLowerCase() === language.toLowerCase()))
  return matches.length === 1 ? matches[0] : null
}

export function selectAudioTrack(menu, track) {
  if (menu.selected !== track.id) {
    menu.dispatchEvent(new CustomEvent("mediaaudiotrackrequest", {
      detail: track.id, bubbles: true, composed: true,
    }))
  }
  return menu.selected === track.id
}

// The player manages the <track> elements it renders. Safari may also expose
// HLS tracks in textTracks that the player explicitly disables.
export function selectEditorSubtitle(player, elements, language, source) {
  const captions = [...elements].filter(el => ["subtitles", "captions"].includes(el.kind))
  const matches = captions.filter(el => el.srclang.toLowerCase() === language.toLowerCase())
  const target = matches.length === 1 ? matches[0] : matches.find(el => el.src === source)
  if (!target) return null

  const previous = captions.map(element => [element, element.track.mode])
  if (target.track.mode !== "showing") {
    // Notify the player of an explicit selection before changing native modes.
    // Otherwise its subtitle sync reapplies the configured default.
    player.dispatchEvent(new CustomEvent("mediashowsubtitlesrequest", {
      detail: [{ kind: target.kind, language: target.srclang, label: target.label }],
      bubbles: true, composed: true,
    }))
  }
  for (const {track} of captions) {
    if (track === target.track) track.mode = "showing"
    else if (track.mode === "showing") track.mode = "disabled"
  }
  return { track: target.track, previous }
}

export function offsetPlayback(player, seconds, duration) {
  player.currentTime = Math.max(0, Math.min(duration, (player.currentTime || 0) + seconds))
}

export function repeatedStep(previous, direction, now, sizes) {
  const repeated = previous && previous.direction === direction && now - previous.at < 350
  const count = repeated ? Math.min(previous.count + 1, sizes.length * 3 - 2) : 1
  return { direction, at: now, count, delta: direction * sizes[Math.floor((count - 1) / 3)] }
}

export function nextSeekStep(previous, direction, now) {
  const step = repeatedStep(previous, direction, now, [1, 5, 10])
  return { ...step, seconds: step.delta }
}

function clock(seconds) {
  const value = Math.max(0, Math.floor(seconds || 0))
  return `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}`
}

export const DescriptionPlaybackHook = {
  mounted() {
    this.subtitle = this.el.dataset.kind === "subtitle"
    this.playButton = this.el.querySelector("[data-play-toggle]")
    this.time = this.el.querySelector("[data-playback-time]")
    this.status = this.el.querySelector("[data-playback-status]")
    this.back = this.el.querySelector("[data-playback-back]")
    this.forward = this.el.querySelector("[data-playback-forward]")
    this.onPlay = () => this.toggle()
    this.form = this.el.closest("form")
    this.onMoment = event => {
      const button = event.target.closest("[data-play-moment]")
      if (button?.hasAttribute("data-pause-moment")) this.player?.pause()
      else if (button) this.toggle(Number(button.dataset.playMoment))
    }
    this.form.addEventListener("click", this.onMoment)
    this.onBack = () => this.skip(-1)
    this.onForward = () => this.skip(1)
    this.onMedia = () => this.sync()
    this.playButton.addEventListener("click", this.onPlay)
    this.back.addEventListener("click", this.onBack)
    this.forward.addEventListener("click", this.onForward)
    this.poll = setInterval(() => this.sync(), 250)
    this.sync()
  },

  bindPlayer() {
    const player = findEditorPlayer(this.el.dataset.playerEmbed)
    if (player === this.player) return
    this.unbindPlayer()
    this.player = player
    this.lastSeek = null
    this.initialized = false
    this.previousTrack = null
    if (!player) return
    for (const event of ["play", "pause", "timeupdate", "loadedmetadata", "volumechange", "ended"]) {
      player.addEventListener(event, this.onMedia)
    }
  },

  unbindPlayer() {
    if (this.subtitleSelection?.track.mode === "showing") {
      const { track, previous } = this.subtitleSelection
      const edited = previous.find(([element]) => element.track === track)
      if (edited[1] !== "showing") {
        // The player also paints captions into its theme. Changing native
        // modes alone can leave the last painted cue visible on a paused video.
        this.player.dispatchEvent(new CustomEvent("mediadisablesubtitlesrequest", {
          detail: [{ kind: edited[0].kind, language: edited[0].srclang, label: edited[0].label }],
          bubbles: true, composed: true,
        }))
      }
      for (const [element, mode] of previous) element.track.mode = mode
      const showing = previous.find(([, mode]) => mode === "showing")
      if (showing && showing[0].track !== track) showing[0].dispatchEvent(new Event("cuechange"))
    }
    this.subtitleSelection = null
    if (this.subtitleFilter !== undefined && this.player?.subtitles === "all") {
      this.player.subtitles = this.subtitleFilter
    }
    this.subtitleFilter = undefined
    if (!this.player) return
    for (const event of ["play", "pause", "timeupdate", "loadedmetadata", "volumechange", "ended"]) {
      this.player.removeEventListener(event, this.onMedia)
    }
  },

  sync() {
    this.bindPlayer()
    this.menu = !this.subtitle && findAudioMenu(this.player?.shadowRoot)
    this.track = descriptionTrack(this.menu, this.el.dataset.trackLabel, this.el.dataset.trackLanguage)
    const available = !!this.player && (this.subtitle || !!this.track)
    if (available && this.subtitle && !this.initialized) {
      const language = this.el.dataset.trackLanguage
      if (language && this.player.subtitles && this.player.subtitles !== "all" &&
          !this.player.subtitles.includes(language)) {
        this.subtitleFilter = this.player.subtitles
        this.player.subtitles = "all"
      }
      const elements = this.player.shadowRoot?.querySelectorAll("video track, audio track") || []
      if (language) {
        this.subtitleSelection = selectEditorSubtitle(this.player, elements, language, this.el.dataset.trackSrc)
        this.initialized = !!this.subtitleSelection
      }
    }
    if (available && !this.subtitle && !this.initialized) {
      this.previousTrack = this.menu.selected
      this.previousTrackLabel = this.menu.tracks.find(track => track.id === this.previousTrack)?.label
      this.initialized = true
      selectAudioTrack(this.menu, this.track)
    }
    this.playButton.disabled = !available || !!this.starting
    this.back.disabled = !available
    this.forward.disabled = !available
    for (const button of [this.playButton, this.back, this.forward]) {
      button.classList.toggle("opacity-50", button.disabled)
      button.classList.toggle("pointer-events-none", button.disabled)
    }
    const playing = available && !this.player.paused
    const icon = this.playButton.querySelector(".hero-play, .hero-pause")
    if (icon) {
      icon.classList.toggle("hero-play", !playing)
      icon.classList.toggle("hero-pause", playing)
    }
    this.playButton.setAttribute("aria-label", playing ? this.el.dataset.pauseLabel : this.el.dataset.playLabel)
    this.time.textContent = `${clock(this.player?.currentTime)} / ${clock(Number(this.el.dataset.duration))}`
    this.el.dispatchEvent(new CustomEvent("description:playhead", {
      detail: { time: this.player?.currentTime, playing }, bubbles: true,
    }))
    if (!this.error) {
      this.status.textContent = this.subtitle ? "" : !available ? this.el.dataset.waitingLabel
        : this.menu.selected === this.track.id ? this.el.dataset.activeLabel : this.el.dataset.inactiveLabel
    }
  },

  async toggle(moment) {
    this.lastSeek = null
    this.sync()
    if (!this.player || (!this.subtitle && !this.track)) return
    if (!Number.isFinite(moment) && !this.player.paused) { this.player.pause(); return }
    if (!this.subtitle && !selectAudioTrack(this.menu, this.track)) {
      this.showError()
      return
    }
    this.starting = true
    this.error = false
    if (!this.subtitle) this.player.muted = false
    if (Number.isFinite(moment)) this.player.currentTime = Math.max(0, moment)
    this.sync()
    try {
      await this.player.play()
    } catch (_error) {
      if (!this.stopped) this.showError()
    } finally {
      this.starting = false
      if (!this.stopped) this.sync()
    }
  },

  skip(direction) {
    if (!this.player) return
    this.lastSeek = nextSeekStep(this.lastSeek, direction, performance.now())
    offsetPlayback(this.player, this.lastSeek.seconds, Number(this.el.dataset.duration))
    this.sync()
  },

  showError() {
    this.error = true
    this.status.textContent = this.el.dataset.errorLabel
  },

  destroyed() {
    this.stopped = true
    clearInterval(this.poll)
    this.unbindPlayer()
    this.playButton.removeEventListener("click", this.onPlay)
    this.form.removeEventListener("click", this.onMoment)
    this.back.removeEventListener("click", this.onBack)
    this.forward.removeEventListener("click", this.onForward)
    if (this.menu && this.track && this.menu.selected === this.track.id && this.previousTrack != null) {
      const previous = this.menu.tracks.find(track => track.id === this.previousTrack && track.label === this.previousTrackLabel)
      if (previous) selectAudioTrack(this.menu, previous)
    }
  },
}
