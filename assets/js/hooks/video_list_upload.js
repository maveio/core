export const MAX_CONCURRENT_UPLOADS = 3

export function hasFiles(event) {
  return Array.from(event.dataTransfer?.types || []).includes("Files")
}

export function droppedFiles(dataTransfer) {
  const files = Array.from(dataTransfer?.files || [])
  const items = Array.from(dataTransfer?.items || []).filter((item) => item.kind === "file")
  if (!files.length || items.some((item) => item.webkitGetAsEntry?.()?.isDirectory)) {
    return { error: "invalidFileMessage" }
  }
  return { files }
}

function within(promise, milliseconds) {
  let timer
  return Promise.race([
    promise,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), milliseconds) }),
  ]).finally(() => clearTimeout(timer))
}

const active = (entry) => ["preparing", "uploading"].includes(entry.state)
const uploaded = (entry) => ["processing", "completed"].includes(entry.state)

export const VideoListUploadHook = {
  mounted() {
    this.entries = []
    this.nextId = 0
    this.disposed = false
    this.listeners = []
    this.status = this.el.querySelector("[data-upload-status]")
    this.listen(this.el, "dragenter", (event) => this.dragOver(event))
    this.listen(this.el, "dragover", (event) => this.dragOver(event))
    this.listen(this.el, "dragleave", (event) => {
      if (!this.el.contains(event.relatedTarget)) this.clearDrag()
    })
    this.listen(this.el, "drop", (event) => this.drop(event))
    this.listen(window, "dragover", (event) => {
      if (hasFiles(event)) {
        event.preventDefault()
        if (!this.el.contains(event.target)) this.clearDrag()
      }
    })
    this.listen(window, "drop", (event) => {
      if (hasFiles(event)) event.preventDefault()
      this.clearDrag()
    })
    this.listen(window, "dragend", () => this.clearDrag())
    this.listen(window, "blur", () => this.clearDrag())
    this.listen(window, "beforeunload", (event) => {
      if (this.pending()) { event.preventDefault(); event.returnValue = "" }
    })
    this.listen(window, "click", (event) => {
      if (!this.pending() || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      const navigation = event.target.closest?.('a[data-phx-link="redirect"], [phx-click="create_video"], [phx-click="create_folder"]')
      if (navigation && navigation.target !== "_blank" && !window.confirm(this.el.dataset.leaveMessage)) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }, true)
    this.listen(this.status, "click", (event) => {
      const retry = event.target.closest?.("[data-upload-retry]")
      if (retry) this.retry(this.entries.find((entry) => entry.id === retry.closest("[data-upload-id]")?.dataset.uploadId))
    })
  },

  listen(target, name, listener, options) {
    target.addEventListener(name, listener, options)
    this.listeners.push(() => target.removeEventListener(name, listener, options))
  },

  updated() {
    // LiveView may replace a folder row while its upload count changes.
    if (this.targetFolder && !this.el.contains(this.targetFolder)) this.clearDrag()
  },

  disconnected() { this.clearDrag() },

  destroyed() {
    this.disposed = true
    this.clearDrag()
    this.listeners.forEach((remove) => remove())
    this.entries.forEach((entry) => this.disposeEntry(entry))
    this.entries = []
  },

  disposeEntry(entry) {
    entry.cancelReady?.()
    entry.component?.remove()
    entry.file = null
  },

  pending() { return this.entries.some((entry) => entry.state === "queued" || active(entry)) },

  dragOver(event) {
    if (!hasFiles(event)) return
    event.preventDefault()
    const blocked = this.el.dataset.uploadDisabled === "true"
    event.dataTransfer.dropEffect = blocked ? "none" : "copy"
    this.clearDrag()
    this.el.dataset.dropActive = "true"
    const folder = event.target.closest?.("[data-target-folder-id]")
    if (!blocked && folder && this.el.contains(folder)) {
      this.targetFolder = folder
      folder.setAttribute("data-file-drop-target", "")
    }
    const destination = this.targetFolder?.dataset.uploadFolderName || this.el.dataset.destination
    this.el.querySelector("[data-drop-label]").textContent = blocked ? this.el.dataset.disabledMessage :
      this.targetFolder ? this.el.dataset.dropFolderLabel.replace("%{folder}", destination) : this.el.dataset.dropLabel
  },

  clearDrag() {
    this.el.dataset.dropActive = "false"
    this.targetFolder?.removeAttribute("data-file-drop-target")
    this.targetFolder = null
  },

  drop(event) {
    if (!hasFiles(event)) return
    event.preventDefault()
    event.stopPropagation()
    const folder = event.target.closest?.("[data-target-folder-id]")
    const target = folder && this.el.contains(folder) ? folder : null
    const folderId = target?.dataset.targetFolderId || this.el.dataset.folderId || ""
    const destination = target?.dataset.uploadFolderName || this.el.dataset.destination
    this.clearDrag()
    if (this.el.dataset.uploadDisabled === "true") return this.notice(this.el.dataset.disabledMessage)
    const selection = droppedFiles(event.dataTransfer)
    if (selection.error) return this.notice(this.el.dataset[selection.error])

    this.notice("")
    if (!this.entries.length) this.el.querySelector("[data-upload-rows]").replaceChildren()
    for (const [index, file] of selection.files.entries()) {
      const row = this.el.querySelector("[data-upload-template]").content.firstElementChild.cloneNode(true)
      const entry = { id: String(++this.nextId), file, name: file.name, folderId, destination, state: "queued", progress: 0, row }
      row.dataset.uploadId = entry.id
      row.style.animationDelay = `${Math.min(index, 4) * 60}ms`
      row.querySelector("[data-upload-name]").textContent = entry.name
      row.querySelector("[data-upload-name]").setAttribute("title", `${entry.name} · ${destination}`)
      this.entries.push(entry)
      this.el.querySelector("[data-upload-rows]").appendChild(row)
      this.renderEntry(entry)
    }
    this.status.classList.add("is-open")
    this.status.inert = false
    this.status.setAttribute("aria-hidden", "false")
    this.pump()
  },

  pump() {
    if (this.disposed) return
    let slots = MAX_CONCURRENT_UPLOADS - this.entries.filter(active).length
    for (const entry of this.entries) {
      if (slots <= 0) break
      if (entry.state !== "queued") continue
      slots--
      entry.state = "preparing"
      this.renderEntry(entry)
      void this.startEntry(entry)
    }
  },

  async startEntry(entry) {
    try {
      if (!entry.component?.token) {
        await within(customElements.whenDefined("mave-upload"), 30000)
        if (this.disposed) return
        const component = document.createElement("mave-upload")
        if (entry.file.size === 0 || !component.isSupportedFile(entry.file)) {
          entry.file = null
          return this.fail(entry, this.el.dataset.invalidFileMessage)
        }
        entry.component?.remove()
        entry.component = component
        this.el.querySelector("[data-upload-host]").appendChild(component)
        this.bindUpload(entry, component)
        // Each queued file gets its own scoped token and quota check.
        const response = await within(new Promise((resolve) => {
          this.pushEvent("prepare_video_upload", {
            name: entry.name, size: entry.file.size, file_count: 1, folder_id: entry.folderId,
          }, resolve)
        }), 15000)
        if (this.disposed) return
        if (!response.ok) {
          entry.file = null
          return this.fail(entry, response.error)
        }
        entry.href = response.href
        component.token = response.token
      }
      await this.waitUntilReady(entry)
      if (this.disposed || !active(entry)) return
      entry.state = "uploading"
      this.renderEntry(entry)
      entry.component.upload(entry.file)
    } catch (_) {
      if (!this.disposed && active(entry)) this.fail(entry, this.el.dataset.connectionMessage)
    }
  },

  bindUpload(entry, component) {
    component.addEventListener("progress", (event) => {
      if (this.disposed || !active(entry)) return
      entry.progress = Math.min(100, Math.max(0, Math.round(event.detail?.progress || 0)))
      this.renderEntry(entry)
    })
    component.addEventListener("processing", () => {
      if (this.disposed || !active(entry)) return
      entry.state = "processing"
      entry.file = null
      entry.progress = 100
      this.renderEntry(entry)
      this.pump()
    })
    component.addEventListener("completed", () => {
      if (this.disposed || !uploaded(entry)) return
      entry.state = "completed"
      this.renderEntry(entry)
      component.remove()
    })
    for (const name of ["failed", "error", "invalid"]) {
      component.addEventListener(name, (event) => {
        if (!this.disposed && active(entry)) this.fail(entry, event.detail?.message || this.el.dataset.errorMessage)
      })
    }
  },

  waitUntilReady(entry) {
    if (entry.component.hasAttribute("ready")) return Promise.resolve()
    return new Promise((resolve, reject) => {
      const observer = new MutationObserver(() => {
        if (entry.component.hasAttribute("ready")) finish()
      })
      const finish = (error) => {
        observer.disconnect()
        clearTimeout(timer)
        entry.cancelReady = null
        error ? reject(error) : resolve()
      }
      const timer = setTimeout(() => finish(new Error("timeout")), 15000)
      entry.cancelReady = () => finish(new Error("cancelled"))
      observer.observe(entry.component, { attributes: true, attributeFilter: ["ready"] })
    })
  },

  retry(entry) {
    if (!entry || entry.state !== "error" || !entry.file || !entry.component?.token) return
    entry.state = "queued"
    entry.error = null
    this.renderEntry(entry)
    this.pump()
  },

  fail(entry, message) {
    entry.state = "error"
    entry.error = message
    entry.cancelReady?.()
    if (!entry.component?.token) {
      entry.component?.remove()
      entry.file = null
    }
    this.renderEntry(entry)
    this.pump()
  },

  notice(message) {
    const notice = this.el.querySelector("[data-upload-notice]")
    notice.textContent = message
    notice.classList.toggle("hidden", !message)
  },

  renderEntry(entry) {
    const row = entry.row
    row.dataset.state = entry.state
    row.dataset.progressStatus = entry.state === "queued" ? "queued" : entry.state === "error" ? "failed" :
      entry.state === "completed" ? "completed" : "active"
    row.title = entry.error || this.el.dataset[`${entry.state}Message`]
    row.querySelector("[data-upload-message]").textContent = entry.error || this.el.dataset[`${entry.state}Message`]
    row.querySelector("[data-upload-percent]").textContent = `${entry.progress}%`
    row.querySelector("[data-upload-percent]").classList.toggle("hidden", !active(entry))
    const progressFill = row.querySelector("[data-progress-fill]")
    progressFill.style.width = `${entry.progress}%`
    progressFill.classList.toggle("hidden", entry.progress === 0)
    row.querySelector("[data-upload-progress]").setAttribute("aria-valuenow", entry.progress)
    row.querySelector("[data-upload-progress]").setAttribute("aria-label", entry.name)
    row.querySelector("[data-upload-progress]").classList.toggle("hidden", entry.state !== "queued" && !active(entry))
    row.querySelector("[data-upload-retry]").classList.toggle("hidden", entry.state !== "error" || !entry.file || !entry.component?.token)
    const link = row.querySelector("[data-upload-link]")
    if (entry.href && uploaded(entry)) link.href = entry.href
    else link.removeAttribute("href")
  },
}
