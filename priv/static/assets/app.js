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
      case "u":
        return `<u>${children}</u>`
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
      case "li": {
        const parentTag = node.parentElement?.tagName?.toLowerCase()

        if (parentTag === "ol") {
          const siblings = Array.from(node.parentElement.children).filter(
            (child) => child.tagName?.toLowerCase() === "li",
          )
          const index = siblings.indexOf(node)
          const order = index >= 0 ? index + 1 : 1
          return `${order}. ${children}\n`
        }

        return `- ${children}\n`
      }
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

  Hooks.AutosaveToast = {
    mounted() {
      this.messageEl = this.el.querySelector("[data-autosave-message]")
      this.hideTimer = null

      this.handleServerEvent = (payload) => {
        this.show(payload?.state, payload?.message)
      }

      this.handleLocalEvent = (event) => {
        this.show(event?.detail?.state, event?.detail?.message)
      }

      this.handleEvent("autosave:status", this.handleServerEvent)
      window.addEventListener("sa:autosave:status", this.handleLocalEvent)
      this.hide()
    },

    destroyed() {
      window.removeEventListener("sa:autosave:status", this.handleLocalEvent)
      if (this.hideTimer) clearTimeout(this.hideTimer)
    },

    show(state, message) {
      const normalizedState = ["saving", "saved", "error"].includes(state) ? state : "saved"
      const normalizedMessage = this.defaultMessage(normalizedState, message)

      this.el.classList.remove("is-hidden", "is-saving", "is-saved", "is-error")
      this.el.classList.add("is-visible", `is-${normalizedState}`)

      if (this.messageEl) {
        this.messageEl.textContent = normalizedMessage
      }

      if (this.hideTimer) clearTimeout(this.hideTimer)

      if (normalizedState !== "saving") {
        const waitMs = normalizedState === "error" ? 4500 : 1700
        this.hideTimer = setTimeout(() => this.hide(), waitMs)
      }
    },

    hide() {
      this.el.classList.remove("is-visible", "is-saving", "is-saved", "is-error")
      this.el.classList.add("is-hidden")
    },

    defaultMessage(state, message) {
      if (message && message.trim() !== "") return message

      switch (state) {
        case "saving":
          return "Saving changes..."
        case "error":
          return "Could not save changes"
        default:
          return "All changes saved"
      }
    },
  }

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
      this.saveEvent = this.el.dataset.saveEvent || "autosave_body"

      this.handleInput = debounce(() => {
        const markdown = nodeToMarkdown(this.el).replace(/\n{3,}/g, "\n\n").trim()
        this.pushEvent(this.saveEvent, { body: markdown })
      }, 500)

      this.el.addEventListener("input", () => {
        window.dispatchEvent(
          new CustomEvent("sa:autosave:status", {
            detail: { state: "saving", message: "Saving changes..." },
          }),
        )
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
        case "underline":
          document.execCommand("underline", false)
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
