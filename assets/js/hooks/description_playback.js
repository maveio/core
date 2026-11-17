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

export function offsetPlayback(player, seconds, duration) {
  player.currentTime = Math.max(0, Math.min(duration, (player.currentTime || 0) + seconds))
}

export function nextSeekStep(previous, direction, now) {
  const repeated = previous && previous.direction === direction && now - previous.at < 350
  const count = repeated ? Math.min(previous.count + 1, 7) : 1
  const seconds = count <= 3 ? 1 : count <= 6 ? 5 : 10
  return { direction, at: now, count, seconds: direction * seconds }
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
    if (this.selectedSubtitle?.mode === "showing") {
      for (const [track, mode] of this.subtitleModes) track.mode = mode
    }
    this.selectedSubtitle = null
    this.subtitleModes = null
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
      const tracks = Array.from(this.player.shadowRoot?.querySelector("video, audio")?.textTracks || [])
        .filter(track => ["captions", "subtitles"].includes(track.kind))
      const matches = tracks.filter(track => track.language === this.el.dataset.trackLanguage)
      if (matches.length === 1) {
        this.subtitleModes = tracks.map(track => [track, track.mode])
        this.selectedSubtitle = matches[0]
        for (const track of tracks) {
          if (track === this.selectedSubtitle) track.mode = "showing"
          else if (track.mode === "showing") track.mode = "disabled"
        }
        this.initialized = true
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
      detail: { time: this.player?.currentTime }, bubbles: true,
    }))
    if (!this.error) {
      this.status.textContent = this.subtitle ? "" : !available ? this.el.dataset.waitingLabel
        : this.menu.selected === this.track.id ? this.el.dataset.activeLabel : this.el.dataset.inactiveLabel
    }
  },

  async toggle() {
    this.lastSeek = null
    this.sync()
    if (!this.player || (!this.subtitle && !this.track)) return
    if (!this.player.paused) { this.player.pause(); return }
    if (!this.subtitle && !selectAudioTrack(this.menu, this.track)) {
      this.showError()
      return
    }
    this.starting = true
    this.error = false
    if (!this.subtitle) this.player.muted = false
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
    this.back.removeEventListener("click", this.onBack)
    this.forward.removeEventListener("click", this.onForward)
    if (this.menu && this.track && this.menu.selected === this.track.id && this.previousTrack != null) {
      const previous = this.menu.tracks.find(track => track.id === this.previousTrack && track.label === this.previousTrackLabel)
      if (previous) selectAudioTrack(this.menu, previous)
    }
  },
}
