// Connects the chapter editor to the preview player on the video page.
//
// The editor's draft is shown on the player's timeline as a chapters text
// track, so chapters can be checked before they are published. Rows can seek
// the player, and a new chapter can start at the current playback time.

export function chapterCues(chapters, duration) {
  const sorted = [...chapters]
    .filter((chapter) => Number.isFinite(chapter.start) && chapter.title)
    .sort((left, right) => left.start - right.start)

  return sorted.flatMap((chapter, index) => {
    const next = sorted[index + 1]
    const end = next ? next.start : Math.max(duration || 0, chapter.start + 1)
    return end > chapter.start ? [{ start: chapter.start, end, title: chapter.title }] : []
  })
}

const TRACK_LABEL = "mave-chapter-preview"

export const ChaptersHook = {
  mounted() {
    this.onVideoReady = (event) => {
      // The event fires before the element is attached to the player, so keep
      // the element it carries instead of looking it up.
      if (event.target === this.player() && event.detail?.textTracks) this.media = event.detail
      this.sync()
    }
    this.onClick = (event) => {
      const seek = event.target.closest("[data-chapter-seek]")
      if (seek && this.el.contains(seek)) {
        this.seek(Number(seek.dataset.chapterSeek))
        return
      }

      const add = event.target.closest("[data-chapter-add]")
      if (add && this.el.contains(add)) {
        this.pushEventTo(this.el, "add_chapter", { time: this.video()?.currentTime || 0 })
      }
    }

    // A new chapter gets a placeholder title: select it so typing replaces it.
    this.onFocus = (event) => {
      if (event.target.matches?.("[data-chapter-new]")) event.target.select()
    }

    // The player announces its <video> element once it has built its shadow DOM.
    document.addEventListener("mave:video_element_ready", this.onVideoReady)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("focusin", this.onFocus)
    this.sync()
  },

  updated() {
    this.sync()
  },

  destroyed() {
    document.removeEventListener("mave:video_element_ready", this.onVideoReady)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("focusin", this.onFocus)
    this.clear(this.video())
    this.media = null
  },

  player() {
    const container = document.getElementById(this.el.dataset.playerContainer)
    return container?.querySelector("mave-player, mave-audio") || null
  },

  video() {
    const attached = this.player()?.shadowRoot?.querySelector("video, audio")
    if (attached) this.media = attached
    return this.media || null
  },

  seek(time) {
    const video = this.video()
    if (!video || !Number.isFinite(time)) return
    video.currentTime = time
    this.player()?.scrollIntoView({ behavior: "smooth", block: "center" })
  },

  track(video) {
    const existing = [...video.textTracks].find(
      (track) => track.kind === "chapters" && track.label === TRACK_LABEL
    )
    return existing || video.addTextTrack("chapters", TRACK_LABEL)
  },

  clear(video) {
    if (!video) return
    const track = [...video.textTracks].find(
      (candidate) => candidate.kind === "chapters" && candidate.label === TRACK_LABEL
    )
    if (!track) return
    track.mode = "hidden"
    ;[...(track.cues || [])].forEach((cue) => track.removeCue(cue))
  },

  sync() {
    const video = this.video()
    if (!video || typeof VTTCue === "undefined") return

    let chapters = []
    try {
      chapters = JSON.parse(this.el.dataset.chapters || "[]")
    } catch (_error) {
      chapters = []
    }

    const track = this.track(video)
    // Cues can only be edited while the track is loaded.
    track.mode = "hidden"
    ;[...(track.cues || [])].forEach((cue) => track.removeCue(cue))

    chapterCues(chapters, Number(this.el.dataset.duration) || video.duration || 0).forEach((cue) =>
      track.addCue(new VTTCue(cue.start, cue.end, cue.title))
    )

    // Players read chapters when a text track changes; toggling the mode is the
    // one change event a script can cause on an existing track.
    track.mode = "disabled"
    track.mode = "hidden"
  },
}
