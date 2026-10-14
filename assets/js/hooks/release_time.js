// Scheduled releases are stored in UTC; the dashboard works in local time.

const pad = value => String(value).padStart(2, "0")

const toLocalInputValue = date =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`

const timeZoneName = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone
  } catch (_error) {
    return null
  }
}

// Fills the hidden `release[at]` field with an ISO 8601 UTC time.
export const ReleaseTimeInputHook = {
  mounted() {
    this.local = this.el.querySelector("input[type='datetime-local']")
    this.utc = this.el.querySelector("input[name='release[at]']")
    this.sync = () => {
      const date = this.local.value ? new Date(this.local.value) : null
      this.utc.value = date && !Number.isNaN(date.getTime()) ? date.toISOString() : ""
    }

    this.local.addEventListener("input", this.sync)
    this.local.addEventListener("change", this.sync)
    this.el.addEventListener("submit", this.sync, true)
    this.prepare()
  },

  updated() {
    this.prepare()
  },

  destroyed() {
    this.local?.removeEventListener("input", this.sync)
    this.local?.removeEventListener("change", this.sync)
    this.el.removeEventListener("submit", this.sync, true)
  },

  prepare() {
    this.local.min = toLocalInputValue(new Date(Date.now() + 60_000))

    const releaseAt = Number(this.el.dataset.releaseAt)
    if (!this.local.value && releaseAt > 0) {
      this.local.value = toLocalInputValue(new Date(releaseAt * 1000))
    }

    const zone = this.el.querySelector("[data-role='time-zone']")
    const name = timeZoneName()
    if (zone && name) zone.textContent = name

    this.sync()
  },
}

// Renders a <time datetime="..."> in the viewer's locale and time zone.
export const LocalTimeHook = {
  mounted() {
    this.render()
  },

  updated() {
    this.render()
  },

  render() {
    const date = new Date(this.el.getAttribute("datetime"))
    if (Number.isNaN(date.getTime())) return

    this.el.textContent = new Intl.DateTimeFormat(undefined, {
      dateStyle: "long",
      timeStyle: "short",
      timeZoneName: "short",
    }).format(date)
  },
}
