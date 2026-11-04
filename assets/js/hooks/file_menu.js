export const FileMenuHook = {
  mounted() {
    this.onClick = (event) => {
      const trigger = event.target.closest("[data-file-menu-trigger='true']")
      if (trigger && this.el.contains(trigger)) {
        this.isOpen ? this.closeMenu() : this.openMenu(event.detail === 0)
      } else if (event.target.closest("[role='menuitem']")) {
        this.closeMenu()
      }
    }
    this.onOutside = (event) => {
      if (!this.el.contains(event.target)) this.closeMenu()
    }
    this.onKey = (event) => {
      if (!this.isOpen) return
      if (event.key === "Escape") {
        event.preventDefault()
        this.closeMenu(true)
      } else if (event.key === "Tab") {
        this.closeMenu()
      } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault()
        const items = [...this.panel.querySelectorAll("[role='menuitem']:not(:disabled)")]
        const current = items.indexOf(document.activeElement)
        const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 :
          current < 0 ? (event.key === "ArrowDown" ? 0 : items.length - 1) :
          (current + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length
        items[next]?.focus()
      }
    }
    this.onScroll = (event) => {
      if (this.isOpen && !this.panel?.contains(event.target)) this.positionMenu()
    }
    this.onResize = () => this.closeMenu()
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKey)
    document.addEventListener("pointerdown", this.onOutside)
    document.addEventListener("scroll", this.onScroll, true)
    window.addEventListener("resize", this.onResize)
  },

  updated() {
    this.closeMenu()
  },

  openMenu(focusFirst = false) {
    this.trigger = this.el.querySelector("[data-file-menu-trigger='true']")
    this.panel = this.el.querySelector("[data-file-menu-panel]")
    if (!this.trigger || !this.panel) return

    // Keep the menu clear of the narrow sidebar's scroll clipping and viewport edges.
    this.panel.style.display = "block"
    this.positionMenu()
    this.trigger.setAttribute("aria-expanded", "true")
    this.isOpen = true
    if (focusFirst) this.panel.querySelector("[role='menuitem']:not(:disabled)")?.focus({ preventScroll: true })
  },

  positionMenu() {
    const anchor = this.trigger.getBoundingClientRect()
    if (anchor.bottom <= 0 || anchor.top >= window.innerHeight) {
      this.closeMenu()
      return
    }
    const menu = this.panel.getBoundingClientRect()
    const inset = 8
    const rowRight = this.el.parentElement.getBoundingClientRect().right
    const left = Math.max(inset, Math.min(rowRight - menu.width, window.innerWidth - menu.width - inset))
    const top = anchor.bottom + menu.height + inset <= window.innerHeight ?
      anchor.bottom + inset : Math.max(inset, anchor.top - menu.height - inset)
    this.panel.style.left = `${left}px`
    this.panel.style.top = `${top}px`
  },

  closeMenu(returnFocus = false) {
    if (this.panel) this.panel.style.display = "none"
    this.trigger?.setAttribute("aria-expanded", "false")
    this.isOpen = false
    if (returnFocus) this.trigger?.focus({ preventScroll: true })
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKey)
    document.removeEventListener("pointerdown", this.onOutside)
    document.removeEventListener("scroll", this.onScroll, true)
    window.removeEventListener("resize", this.onResize)
  },
}
