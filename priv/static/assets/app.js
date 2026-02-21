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

  Hooks.KnowledgeGraph = {
    mounted() {
      this.canvasEl = this.el.querySelector("[data-graph-canvas]") || this.el
      this.graph = null
      this.graphData = { nodes: [], links: [] }
      this.handleResize = () => this.resize()
      this.controlListeners = []

      this.handleEvent("render_graph", (payload) => {
        this.replaceData(payload)
      })

      this.handleEvent("append_graph", (payload) => {
        this.appendData(payload)
      })

      this.initGraph()
      this.bindControlButtons()
      window.addEventListener("resize", this.handleResize)
      this.pushEvent("init_graph", {})
    },

    destroyed() {
      this.unbindControlButtons()
      window.removeEventListener("resize", this.handleResize)
    },

    initGraph() {
      const createForceGraph = window.ForceGraph

      if (typeof createForceGraph !== "function") {
        return
      }

      this.graph = createForceGraph()(this.canvasEl)
        .nodeId("id")
        .nodeLabel((node) => node.label || node.id || "node")
        .nodeColor((node) => node.color || "#29abe2")
        .nodeVal((node) => node.val || 6)
        .linkColor((link) => link.color || "rgba(104, 123, 135, 0.32)")
        .linkWidth((link) => (link.kind === "relation" ? 1.9 : 1.3))
        .linkLabel((link) => link.label || "")
        .linkDirectionalArrowLength((link) => (link.directional ? 4 : 0))
        .linkDirectionalArrowRelPos(1)
        .cooldownTicks(90)
        .onNodeClick((node) => {
          if (node && node.id) {
            this.pushEvent("expand_node", { node_id: node.id })
          }
        })

      if (typeof this.graph.enableNodeDrag === "function") {
        this.graph.enableNodeDrag(false)
      }

      if (typeof this.graph.enableZoomPanInteraction === "function") {
        this.graph.enableZoomPanInteraction(true)
      } else {
        if (typeof this.graph.enableZoomInteraction === "function") {
          this.graph.enableZoomInteraction(true)
        }

        if (typeof this.graph.enablePanInteraction === "function") {
          this.graph.enablePanInteraction(true)
        }
      }

      if (typeof this.graph.minZoom === "function") this.graph.minZoom(0.12)
      if (typeof this.graph.maxZoom === "function") this.graph.maxZoom(10)

      this.resize()
      this.graph.graphData(this.graphData)
    },

    resize() {
      if (!this.graph) return

      const width = this.canvasEl.clientWidth || 600
      const height = this.canvasEl.clientHeight || 500

      this.graph.width(width)
      this.graph.height(height)
    },

    bindControlButtons() {
      const controls = this.el.querySelectorAll("[data-graph-control]")

      controls.forEach((button) => {
        const action = button.dataset.graphControl
        const handler = () => this.applyControl(action)
        button.addEventListener("click", handler)
        this.controlListeners.push({ button, handler })
      })
    },

    unbindControlButtons() {
      this.controlListeners.forEach(({ button, handler }) => {
        button.removeEventListener("click", handler)
      })
      this.controlListeners = []
    },

    applyControl(action) {
      if (!this.graph) return

      switch (action) {
        case "zoom-in":
          this.adjustZoom(1.2)
          break
        case "zoom-out":
          this.adjustZoom(1 / 1.2)
          break
        case "reset":
          this.resetView()
          break
        default:
          break
      }
    },

    adjustZoom(multiplier) {
      if (typeof this.graph.zoom !== "function") return

      const currentZoom = this.graph.zoom()
      const safeCurrent = typeof currentZoom === "number" && currentZoom > 0 ? currentZoom : 1
      const nextZoom = safeCurrent * multiplier
      this.graph.zoom(nextZoom, 260)
    },

    resetView() {
      if (typeof this.graph.centerAt === "function") this.graph.centerAt(0, 0, 300)
      if (typeof this.graph.zoom === "function") this.graph.zoom(1, 300)
    },

    replaceData(payload) {
      if (!this.graph) this.initGraph()
      if (!this.graph) return

      this.graphData = this.normalizePayload(payload)
      this.graph.graphData(this.graphData)
      this.resize()
    },

    appendData(payload) {
      if (!this.graph) this.initGraph()
      if (!this.graph) return

      const incoming = this.normalizePayload(payload)
      const nextNodes = this.mergeNodes(this.graphData.nodes, incoming.nodes)
      const nextLinks = this.mergeLinks(this.graphData.links, incoming.links)
      this.graphData = { nodes: nextNodes, links: nextLinks }
      this.graph.graphData(this.graphData)
      this.resize()
    },

    normalizePayload(payload) {
      if (!payload || typeof payload !== "object") {
        return { nodes: [], links: [] }
      }

      return {
        nodes: Array.isArray(payload.nodes) ? payload.nodes : [],
        links: Array.isArray(payload.links) ? payload.links : [],
      }
    },

    mergeNodes(currentNodes, incomingNodes) {
      const byId = new Map()

      currentNodes.forEach((node) => {
        const id = node && node.id
        if (id) byId.set(id, node)
      })

      incomingNodes.forEach((node) => {
        const id = node && node.id
        if (id) byId.set(id, node)
      })

      return Array.from(byId.values())
    },

    mergeLinks(currentLinks, incomingLinks) {
      const byId = new Map()

      currentLinks.forEach((link) => {
        const id = this.linkId(link)
        if (id) byId.set(id, link)
      })

      incomingLinks.forEach((link) => {
        const id = this.linkId(link)
        if (id) byId.set(id, link)
      })

      return Array.from(byId.values())
    },

    linkId(link) {
      if (!link || typeof link !== "object") return null
      if (typeof link.id === "string" && link.id !== "") return link.id

      const sourceId = typeof link.source === "object" ? link.source.id : link.source
      const targetId = typeof link.target === "object" ? link.target.id : link.target

      if (!sourceId || !targetId) return null

      return `${sourceId}->${targetId}:${link.kind || ""}:${link.label || ""}`
    },
  }

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

  // Google OAuth popup handler: opens the OAuth flow in a popup window,
  // polls for popup close, and reloads the page to refresh connection status.
  window.addEventListener("phx:open_oauth_popup", (event) => {
    const url = event.detail && event.detail.url
    if (!url) return

    const popup = window.open(
      url,
      "google_oauth",
      "width=600,height=700,scrollbars=yes",
    )

    if (!popup) {
      // Popup was blocked — fall back to a direct navigation.
      window.location.href = url
      return
    }

    const pollInterval = setInterval(() => {
      if (popup.closed) {
        clearInterval(pollInterval)
        window.location.reload()
      }
    }, 500)
  })

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")
  const LiveSocket =
    window.LiveSocket || window.LiveView?.LiveSocket || window.Phoenix?.LiveView?.LiveSocket || window.Phoenix?.LiveSocket
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
