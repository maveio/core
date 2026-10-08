// The fragment stays in the browser: never put the owner code in a query string.
export function initializeSetup(document, location, history) {
  if (!location.hash.startsWith("#code=")) return

  const code = new URLSearchParams(location.hash.slice(1)).get("code")
  history.replaceState(history.state, "", location.pathname + location.search)
  const form = document.getElementById("setup-form")
  if (!form || !/^[a-f0-9]{48}$/.test(code || "")) return

  const input = form.querySelector('[name="setup[code]"]')
  const manual = document.getElementById("setup-manual-code")
  const received = document.getElementById("setup-link-received")
  if (!input || !manual || !received) return

  input.value = code
  manual.hidden = true
  received.hidden = false
  document.getElementById("setup-change-code").addEventListener("click", () => {
    manual.hidden = false
    received.hidden = true
    input.focus()
  })
  form.querySelector('[name="setup[email]"]')?.focus()
}

if (typeof document !== "undefined") {
  const initialize = () => initializeSetup(document, window.location, window.history)
  initialize()
  window.addEventListener("hashchange", initialize)
}
