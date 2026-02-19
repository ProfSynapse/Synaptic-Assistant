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

  Hooks.WorkflowRichEditor = {
    mounted() {
      this.statusEl = document.getElementById("workflow-editor-status")
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

      this.bindToolbarButtons()
    },

    bindToolbarButtons() {
      const selector = `[data-editor-target="${this.el.id}"]`
      const buttons = document.querySelectorAll(selector)

      buttons.forEach((button) => {
        button.addEventListener("click", () => {
          const cmd = button.dataset.editorCmd
          this.applyCommand(cmd)
          this.el.dispatchEvent(new Event("input", { bubbles: true }))
        })
      })
    },

    applyCommand(cmd) {
      this.el.focus()

      switch (cmd) {
        case "bold":
          document.execCommand("bold", false)
          break
        case "italic":
          document.execCommand("italic", false)
          break
        case "h1":
          document.execCommand("formatBlock", false, "h1")
          break
        case "h2":
          document.execCommand("formatBlock", false, "h2")
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

