function encodeMetadataValue(value) {
  return btoa(unescape(encodeURIComponent(String(value))))
}

function uploadMetadata(file, meta) {
  return Object.entries({ filetype: file.type, ...meta })
    .filter(([, value]) => value !== null && value !== undefined && value !== "")
    .map(([key, value]) => `${key} ${encodeMetadataValue(value)}`)
    .join(",")
}

function requestErrorMessage(xhr) {
  const body = xhr.responseText?.trim()
  return body !== "" ? body : `Upload failed with status ${xhr.status}`
}

function resolveUploadUrl(entrypoint, locationHeader) {
  if (!locationHeader) {
    throw new Error("Tus server did not return a Location header")
  }

  return new URL(locationHeader, entrypoint).toString()
}

export function cdn(entries, onViewError) {
  entries.forEach((entry) => {
    const { file, meta } = entry
    const createRequest = new XMLHttpRequest()
    let patchRequest = null

    onViewError(() => {
      createRequest.abort()

      if (patchRequest) {
        patchRequest.abort()
      }
    })

    createRequest.open("POST", meta.entrypoint, true)
    createRequest.setRequestHeader("Tus-Resumable", "1.0.0")
    createRequest.setRequestHeader("Upload-Length", file.size)
    createRequest.setRequestHeader("Upload-Metadata", uploadMetadata(file, meta))

    createRequest.onerror = () => entry.error(requestErrorMessage(createRequest))

    createRequest.onload = () => {
      if (createRequest.status < 200 || createRequest.status >= 300) {
        entry.error(requestErrorMessage(createRequest))
        return
      }

      let uploadUrl

      try {
        uploadUrl = resolveUploadUrl(meta.entrypoint, createRequest.getResponseHeader("Location"))
      } catch (error) {
        entry.error(error.message)
        return
      }

      patchRequest = new XMLHttpRequest()
      patchRequest.open("PATCH", uploadUrl, true)
      patchRequest.setRequestHeader("Tus-Resumable", "1.0.0")
      patchRequest.setRequestHeader("Upload-Offset", "0")
      patchRequest.setRequestHeader("Content-Type", "application/offset+octet-stream")

      patchRequest.upload.onprogress = (event) => {
        if (!event.lengthComputable) {
          return
        }

        const progress = Math.round((event.loaded / event.total) * 100)

        if (progress < 100) {
          entry.progress(progress)
        }
      }

      patchRequest.onerror = () => entry.error(requestErrorMessage(patchRequest))

      patchRequest.onload = () => {
        if (patchRequest.status >= 200 && patchRequest.status < 300) {
          entry.progress(100)
        } else {
          entry.error(requestErrorMessage(patchRequest))
        }
      }

      patchRequest.send(file)
    }

    createRequest.send()
  })
}
