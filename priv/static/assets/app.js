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

  Hooks.AccordionControl = {
    mounted() {
      this.handleEvent("accordion:open", ({ id }) => {
        const el = document.getElementById(id)
        if (el) el.open = true
      })
      
      this.handleEvent("accordion:close", ({ id }) => {
        const el = document.getElementById(id)
        if (el) el.open = false
      })
    }
  }

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

    nodeRadius(node) {
      return Math.sqrt(Math.max(4, 2 + (node.connection_count || 0) * 1.5)) * 2
    },

    initGraph() {
      const createForceGraph = window.ForceGraph

      if (typeof createForceGraph !== "function") {
        return
      }

      const self = this

      this.graph = createForceGraph()(this.canvasEl)
        .nodeId("id")
        .nodeLabel("")
        .nodeVal((node) => Math.max(4, 2 + (node.connection_count || 0) * 1.5))
        .nodeCanvasObject((node, ctx, globalScale) => {
          const r = self.nodeRadius(node)
          const fontSize = Math.max(10 / globalScale, 1.5)
          const nodeOpacity = node._opacity !== undefined ? node._opacity : 1

          ctx.globalAlpha = nodeOpacity

          // Glow
          ctx.shadowColor = node.color || "#29abe2"
          ctx.shadowBlur = nodeOpacity > 0.5 ? 8 : 0

          // Circle
          ctx.beginPath()
          ctx.arc(node.x, node.y, r, 0, 2 * Math.PI)
          ctx.fillStyle = node.color || "#29abe2"
          ctx.fill()

          ctx.shadowBlur = 0

          // Label (only if zoomed in enough)
          if (globalScale > 0.7) {
            ctx.font = `${fontSize}px Sans-Serif`
            ctx.textAlign = "center"
            ctx.textBaseline = "top"
            ctx.fillStyle = `rgba(220, 225, 230, ${nodeOpacity})`
            ctx.fillText(node.label || "", node.x, node.y + r + 2)
          }

          ctx.globalAlpha = 1
        })
        .nodePointerAreaPaint((node, color, ctx) => {
          const r = self.nodeRadius(node)
          ctx.beginPath()
          ctx.arc(node.x, node.y, r, 0, 2 * Math.PI)
          ctx.fillStyle = color
          ctx.fill()
        })
        .linkColor((link) => link.color || "rgba(104, 123, 135, 0.32)")
        .linkWidth((link) => (link.kind === "relation" ? 1.9 : 1.3))
        .linkLineDash((link) => (link.kind === "mention" ? [4, 2] : null))
        .linkLabel((link) => link.label || "")
        .linkDirectionalArrowLength((link) => (link.directional ? 4 : 0))
        .linkDirectionalArrowRelPos(1)
        .backgroundColor("transparent")
        .cooldownTicks(Infinity)
        .d3AlphaDecay(0.008)
        .d3VelocityDecay(0.3)
        .onNodeHover((hoveredNode) => {
          self.canvasEl.style.cursor = hoveredNode ? "pointer" : "grab"

          if (hoveredNode) {
            const neighborIds = new Set()
            neighborIds.add(hoveredNode.id)

            self.graphData.links.forEach((link) => {
              const sourceId = typeof link.source === "object" ? link.source.id : link.source
              const targetId = typeof link.target === "object" ? link.target.id : link.target
              if (sourceId === hoveredNode.id) neighborIds.add(targetId)
              if (targetId === hoveredNode.id) neighborIds.add(sourceId)
            })

            self.graphData.nodes.forEach((n) => {
              n._opacity = neighborIds.has(n.id) ? 1 : 0.12
            })
          } else {
            self.graphData.nodes.forEach((n) => {
              n._opacity = 1
            })
          }

          self.graph.linkColor((link) => {
            if (!hoveredNode) return link.color || "rgba(104, 123, 135, 0.32)"
            const sourceId = typeof link.source === "object" ? link.source.id : link.source
            const targetId = typeof link.target === "object" ? link.target.id : link.target
            const isConnected = sourceId === hoveredNode.id || targetId === hoveredNode.id
            return isConnected
              ? (link.color || "rgba(104, 123, 135, 0.8)")
              : "rgba(104, 123, 135, 0.05)"
          })
        })
        .onNodeClick((node) => {
          if (!node || !node.id) return
          const parts = node.id.split(":")
          if (parts.length >= 2) {
            self.pushEvent("navigate_node", { kind: parts[0], id: parts.slice(1).join(":") })
          }
        })

      if (typeof this.graph.enableNodeDrag === "function") {
        this.graph.enableNodeDrag(true)
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
      if (typeof this.graph.zoomToFit === "function") this.graph.zoomToFit(300, 40)
    },

    replaceData(payload) {
      if (!this.graph) this.initGraph()
      if (!this.graph) return

      this.graphData = this.normalizePayload(payload)
      this.graphData.nodes.forEach((n) => { n._opacity = 1 })
      this.graph.graphData(this.graphData)
      this.resize()
      setTimeout(() => {
        if (this.graph) this.graph.zoomToFit(400, 40)
      }, 600)
    },

    appendData(payload) {
      if (!this.graph) this.initGraph()
      if (!this.graph) return

      const incoming = this.normalizePayload(payload)
      const nextNodes = this.mergeNodes(this.graphData.nodes, incoming.nodes)
      const nextLinks = this.mergeLinks(this.graphData.links, incoming.links)
      this.graphData = { nodes: nextNodes, links: nextLinks }
      this.graphData.nodes.forEach((n) => { n._opacity = 1 })
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

  Hooks.ScrollToBottom = {
    mounted() {
      this.el.scrollTop = this.el.scrollHeight
    },

    updated() {
      const threshold = 100
      const distanceFromBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight

      if (distanceFromBottom <= threshold) {
        this.el.scrollTo({ top: this.el.scrollHeight, behavior: "smooth" })
      }
    },
  }

  Hooks.WorkspaceComposer = {
    mounted() {
      this.handleKeydown = (event) => {
        if (event.key !== "Enter") return
        if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return
        if (event.isComposing || event.keyCode === 229) return
        if (!(event.target instanceof HTMLTextAreaElement)) return

        event.preventDefault()

        if (typeof this.el.requestSubmit === "function") {
          this.el.requestSubmit()
        } else {
          this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      }

      this.el.addEventListener("keydown", this.handleKeydown)
    },

    destroyed() {
      this.el.removeEventListener("keydown", this.handleKeydown)
    },
  }

  // OAuth popup handler: opens the OAuth flow in a popup window,
  // polls for popup close, and reloads the page to refresh connection status.
  window.addEventListener("phx:open_oauth_popup", (event) => {
    const url = event.detail && event.detail.url
    const popupName = (event.detail && event.detail.name) || "oauth_popup"
    if (!url) return

    const popup = window.open(
      url,
      popupName,
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

  Hooks.MarketingReveal = {
    mounted() {
      const page = this.el
      const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-revealed')
            observer.unobserve(entry.target)
          }
        })
      }, { threshold: 0.1 })
      page.querySelectorAll('[data-reveal]').forEach(el => {
        el.style.opacity = '0'
        el.style.transform = 'translateY(40px)'
        el.style.transition = 'opacity 0.7s ease, transform 0.7s ease'
        observer.observe(el)
      })
      this._observer = observer
    },
    destroyed() {
      if (this._observer) this._observer.disconnect()
    }
  }

  Hooks.HeroBeaker = {
    mounted() {
      const canvas = this.el
      const ctx = canvas.getContext('2d')
      let frame = 0
      let running = true
      const frames = []
      let loaded = 0

      function resize() {
        canvas.width = canvas.offsetWidth
        canvas.height = canvas.offsetHeight
      }

      function draw() {
        const img = frames[frame]
        if (!img || !img.complete || !img.naturalWidth) return
        ctx.clearRect(0, 0, canvas.width, canvas.height)
        const scale = canvas.height / img.naturalHeight
        const drawW = img.naturalWidth * scale
        const drawH = img.naturalHeight * scale
        const x = (canvas.width - drawW) / 2
        ctx.drawImage(img, x, 0, drawW, drawH)
      }

      function tick() {
        if (!running) return
        draw()
        frame = (frame + 1) % 183
        setTimeout(tick, 80)
      }

      resize()
      window.addEventListener('resize', resize)

      for (let i = 0; i < 183; i++) {
        const img = new Image()
        img.src = `/images/frames/frame_${String(i + 1).padStart(4, '0')}.jpg`
        img.onload = img.onerror = () => {
          loaded++
          if (loaded === 183) tick()
        }
        frames.push(img)
      }

      this._cleanup = () => {
        running = false
        window.removeEventListener('resize', resize)
      }
    },
    destroyed() { if (this._cleanup) this._cleanup() }
  }

  Hooks.ExampleCarousel = {
    mounted() {
      const el = this.el
      let current = 0
      const slides = Array.from(el.querySelectorAll('.sa-carousel-slide'))
      const dots = Array.from(el.querySelectorAll('[data-dot]'))
      const count = slides.length

      function goTo(index) {
        const next = (index + count) % count
        slides[current].classList.remove('is-active')
        dots[current]?.classList.remove('is-active')
        current = next
        slides[current].classList.add('is-active')
        dots[current]?.classList.add('is-active')
        const bubbles = slides[current].querySelectorAll('[data-bubble]')
        bubbles.forEach((b, i) => {
          b.style.opacity = '0'
          b.style.transform = 'translateY(8px)'
          setTimeout(() => {
            b.style.transition = 'opacity 0.3s ease, transform 0.3s ease'
            b.style.opacity = '1'
            b.style.transform = 'translateY(0)'
          }, 100 + i * 120)
        })
      }

      el.querySelector('.sa-carousel-prev')?.addEventListener('click', () => goTo(current - 1))
      el.querySelector('.sa-carousel-next')?.addEventListener('click', () => goTo(current + 1))
      dots.forEach((dot, i) => dot.addEventListener('click', () => goTo(i)))

      goTo(0)
    }
  }

  Hooks.MarketingNav = {
    mounted() {
      const nav = this.el
      const onScroll = () => {
        nav.classList.toggle('is-scrolled', window.scrollY > 20)
      }
      window.addEventListener('scroll', onScroll, { passive: true })
      this._cleanup = () => window.removeEventListener('scroll', onScroll)
    },
    destroyed() {
      if (this._cleanup) this._cleanup()
    }
  }

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
