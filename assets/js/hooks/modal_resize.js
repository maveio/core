// Keep the preferred width when LiveView remounts the same panel.
const widths = new Map()

export const ModalResizeHook = {
  mounted() {
    const panel = this.el
    const handle = panel.querySelector('[role="separator"]')
    const controller = new AbortController()
    this.controller = controller
    const options = { signal: controller.signal }
    const minWidth = 360
    const maxWidth = () => Math.min(panel.parentElement.clientWidth, parseFloat(getComputedStyle(panel).maxWidth))

    const resize = (width) => {
      const value = Math.min(maxWidth(), Math.max(minWidth, width))
      widths.set(handle.id, value)
      panel.style.setProperty("--editor-width", value + "px")
    }
    this.restore = () => {
      if (widths.has(handle.id)) panel.style.setProperty("--editor-width", widths.get(handle.id) + "px")
    }
    this.restore()

    this.observer = new ResizeObserver(() => {
      handle.setAttribute("aria-valuemin", Math.min(minWidth, maxWidth()))
      handle.setAttribute("aria-valuemax", Math.round(maxWidth()))
      handle.setAttribute("aria-valuenow", Math.round(panel.getBoundingClientRect().width))
    })
    this.observer.observe(panel)
    this.observer.observe(panel.parentElement)

    let startX, startWidth
    handle.addEventListener("pointerdown", event => {
      if (!event.isPrimary || event.button !== 0) return
      startX = event.clientX
      startWidth = panel.getBoundingClientRect().width
      handle.setPointerCapture(event.pointerId)
      event.preventDefault()
    }, options)
    handle.addEventListener("pointermove", event => {
      if (handle.hasPointerCapture(event.pointerId)) resize(startWidth + startX - event.clientX)
    }, options)
    handle.addEventListener("keydown", event => {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return
      event.preventDefault()
      resize(panel.getBoundingClientRect().width + (event.key === "ArrowLeft" ? 32 : -32))
    }, options)
  },

  updated() { this.restore() },

  destroyed() {
    this.controller.abort()
    this.observer.disconnect()
  }
}
