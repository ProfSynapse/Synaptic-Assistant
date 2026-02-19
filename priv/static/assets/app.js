(() => {
  function debounce(fn, waitMs) {
    let timeout

    return (...args) => {
      clearTimeout(timeout)
      timeout = setTimeout(() => fn(...args), waitMs)
    }
  }

  function nodeToMarkdown(node) {
    if (!node) return ""

    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent || ""
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return ""
    }

    const tag = node.tagName.toLowerCase()
    const children = Array.from(node.childNodes).map(nodeToMarkdown).join("")

    switch (tag) {
      case "strong":
      case "b":
        return `**${children}**`
      case "em":
      case "i":
        return `*${children}*`
      case "h1":
        return `# ${children}\n\n`
      case "h2":
        return `## ${children}\n\n`
      case "h3":
        return `### ${children}\n\n`
      case "code":
        return `\`${children}\``
      case "a": {
        const href = node.getAttribute("href") || "#"
        return `[${children}](${href})`
      }
      case "li":
        return `- ${children}\n`
      case "ul":
      case "ol":
        return `${children}\n`
      case "br":
        return "\n"
      case "p":
      case "div":
        return `${children}\n\n`
      default:
        return children
    }
  }

  const Hooks = {}

  Hooks.ProfileTimezone = {
    mounted() {
      const input = this.el.querySelector("#profile-timezone-input")

      if (!input) return

      try {
        const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone

        if (timezone && timezone.trim() !== "" && input.value !== timezone) {
          input.value = timezone
          input.dispatchEvent(new Event("change", { bubbles: true }))
        }
      } catch (_error) {
        // Ignore browser timezone detection errors and keep existing value.
      }
    },
  }

  Hooks.WorkflowRichEditor = {
    mounted() {
      const statusTarget = this.el.dataset.statusTarget || "workflow-editor-status"
      this.statusEl = document.getElementById(statusTarget)
      this.saveEvent = this.el.dataset.saveEvent || "autosave_body"

      this.handleInput = debounce(() => {
        const markdown = nodeToMarkdown(this.el).replace(/\n{3,}/g, "\n\n").trim()
        this.pushEvent(this.saveEvent, { body: markdown })
        this.setStatus("Status: Saved")
      }, 500)

      this.el.addEventListener("input", () => {
        this.setStatus("Status: Saving...")
        this.handleInput()
      })

      this.bindToolbarControls()
    },

    bindToolbarControls() {
      const selector = `[data-editor-target="${this.el.id}"]`
      const controls = document.querySelectorAll(selector)

      controls.forEach((control) => {
        if (control.tagName === "SELECT") {
          control.addEventListener("change", () => {
            const cmd = control.dataset.editorCmd
            this.applyCommand(cmd, control.value)
            this.el.dispatchEvent(new Event("input", { bubbles: true }))
          })

          return
        }

        control.addEventListener("click", () => {
          const cmd = control.dataset.editorCmd
          this.applyCommand(cmd)
          this.el.dispatchEvent(new Event("input", { bubbles: true }))
        })
      })
    },

    applyCommand(cmd, value = null) {
      this.el.focus()

      switch (cmd) {
        case "bold":
          document.execCommand("bold", false)
          break
        case "italic":
          document.execCommand("italic", false)
          break
        case "heading": {
          const level = (value || "p").toLowerCase()
          const block = ["h1", "h2", "h3"].includes(level) ? level : "p"
          document.execCommand("formatBlock", false, block)
          break
        }
        case "h1":
        case "h2":
        case "h3":
          document.execCommand("formatBlock", false, cmd)
          break
        case "ul":
          document.execCommand("insertUnorderedList", false)
          break
        case "ol":
          document.execCommand("insertOrderedList", false)
          break
        case "link": {
          const url = window.prompt("Enter URL", "https://")

          if (url && url.trim() !== "") {
            document.execCommand("createLink", false, url.trim())
          }

          break
        }
        case "code": {
          const selection = window.getSelection()
          const selectedText = selection ? selection.toString() : ""

          if (selectedText !== "") {
            document.execCommand("insertHTML", false, `<code>${selectedText}</code>`)
          }

          break
        }
        default:
          break
      }
    },

    setStatus(text) {
      if (this.statusEl) {
        this.statusEl.textContent = text
      }
    },
  }

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")
  const LiveSocket =
    window.LiveSocket || window.Phoenix?.LiveView?.LiveSocket || window.Phoenix?.LiveSocket
  const Socket = window.Phoenix?.Socket

  if (LiveSocket && Socket) {
    const liveSocket = new LiveSocket("/live", Socket, {
      hooks: Hooks,
      params: { _csrf_token: csrfToken },
    })

    liveSocket.connect()
    window.liveSocket = liveSocket
  }
})()
