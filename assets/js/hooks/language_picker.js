import { FileMenuHook } from "./file_menu.js"

const normalize = value => value.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim()

export function matchingLanguages(languages, preferred, selected, query) {
  const term = normalize(query)
  if (!term) {
    const byCode = new Map(languages.map(language => [language.code, language]))
    return [...new Set([selected, ...preferred])].map(code => byCode.get(code)).filter(Boolean)
  }
  return languages.filter(language => language.terms.some(value => normalize(value).includes(term)))
    .sort((a, b) => Number(b.code === term) - Number(a.code === term) || a.label.localeCompare(b.label))
}

export const LanguagePickerHook = {
  ...FileMenuHook,

  mounted() {
    FileMenuHook.mounted.call(this)
    this.enhance()
    this.search = this.el.querySelector("input[type=search]")
    this.results = this.el.querySelector("[data-language-results]")
    this.filter = event => {
      event.stopPropagation()
      this.renderResults()
      this.positionMenu()
    }
    this.searchKeys = event => {
      if (event.key === "Enter") {
        event.preventDefault()
        this.results.querySelector("button")?.click()
      }
      if (["Home", "End"].includes(event.key)) event.stopPropagation()
    }
    this.choose = event => {
      const option = event.target.closest("[data-code]")
      if (!option) return
      this.select.value = option.dataset.code
      this.select.dispatchEvent(new Event("change", { bubbles: true }))
      this.closeMenu(true)
    }
    this.stopSearchChange = event => event.stopPropagation()
    this.search.addEventListener("change", this.stopSearchChange)
    this.search.addEventListener("input", this.filter)
    this.search.addEventListener("keydown", this.searchKeys)
    this.results.addEventListener("click", this.choose)
  },

  enhance() {
    this.select = this.el.querySelector("select")
    this.select.hidden = true
    this.trigger = this.el.querySelector("[data-file-menu-trigger]")
    this.trigger.hidden = false
    this.trigger.classList.add("flex")
  },

  openMenu() {
    this.search.value = ""
    const display = new Intl.DisplayNames(navigator.languages, { type: "language" })
    this.languages = Array.from(this.select.options).filter(option => option.value).map(option => {
      const code = option.value
      const native = new Intl.DisplayNames([code], { type: "language" }).of(code)
      return { code, label: option.text, terms: [code, option.text, native, display.of(code)] }
    })
    this.renderResults()
    FileMenuHook.openMenu.call(this)
    if (this.isOpen) this.search.focus({ preventScroll: true })
  },

  renderResults() {
    const matches = matchingLanguages(this.languages, this.el.dataset.preferred.split(" "), this.select.value, this.search.value)
    this.results.replaceChildren(...matches.map(({ code, label }) => {
      const item = document.createElement("button")
      item.type = "button"
      item.dataset.code = code
      item.tabIndex = -1
      item.setAttribute("role", "menuitem")
      item.className = "block w-full rounded px-2 py-1.5 text-left text-xs cursor-pointer hover:bg-white/5 focus-visible:bg-white/10 focus-visible:outline-none"
      if (code === this.select.value) item.classList.add("text-blue-400")
      item.textContent = label
      return item
    }))
    this.results.scrollTop = 0
    this.el.querySelector("[data-empty]").hidden = matches.length !== 0
  },

  updated() {
    FileMenuHook.updated.call(this)
    this.enhance()
  },

  destroyed() {
    this.search.removeEventListener("change", this.stopSearchChange)
    this.search.removeEventListener("input", this.filter)
    this.search.removeEventListener("keydown", this.searchKeys)
    this.results.removeEventListener("click", this.choose)
    FileMenuHook.destroyed.call(this)
  },
}
