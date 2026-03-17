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

  function reducedMotionPreferred() {
    try {
      return window.matchMedia("(prefers-reduced-motion: reduce)").matches
    } catch (_error) {
      return false
    }
  }

  Hooks.MarketingNav = {
    mounted() {
      this.raf = null
      this.handleScroll = () => {
        if (this.raf) return

        this.raf = window.requestAnimationFrame(() => {
          this.raf = null
          this.el.classList.toggle("is-scrolled", window.scrollY > 18)
        })
      }

      this.handleScroll()
      window.addEventListener("scroll", this.handleScroll, { passive: true })
    },

    destroyed() {
      if (this.raf) window.cancelAnimationFrame(this.raf)
      window.removeEventListener("scroll", this.handleScroll)
    },
  }

  Hooks.MarketingReveal = {
    mounted() {
      this.targets = Array.from(this.el.querySelectorAll("[data-reveal]"))

      if (this.targets.length === 0) return
      if (reducedMotionPreferred() || typeof IntersectionObserver !== "function") {
        this.targets.forEach((target) => target.classList.add("is-visible"))
        return
      }

      this.observer = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (!entry.isIntersecting) return
            entry.target.classList.add("is-visible")
            this.observer.unobserve(entry.target)
          })
        },
        { rootMargin: "0px 0px -10% 0px", threshold: 0.12 },
      )

      this.targets.forEach((target, index) => {
        target.style.setProperty("--sa-reveal-delay", `${index * 45}ms`)
        this.observer.observe(target)
      })
    },

    destroyed() {
      if (this.observer) this.observer.disconnect()
    },
  }

  Hooks.MarketingParallax = {
    mounted() {
      this.layers = Array.from(this.el.querySelectorAll("[data-parallax-layer]"))
      this.raf = null

      if (this.layers.length === 0 || reducedMotionPreferred()) return

      this.handleScroll = () => {
        if (this.raf) return

        this.raf = window.requestAnimationFrame(() => {
          this.raf = null
          const rect = this.el.getBoundingClientRect()
          const progress = (window.innerHeight - rect.top) / (window.innerHeight + rect.height)
          const clamped = Math.max(-0.25, Math.min(1.25, progress))

          this.layers.forEach((layer) => {
            const speed = Number(layer.dataset.parallaxSpeed || "0")
            const y = (clamped - 0.5) * 120 * speed
            layer.style.transform = `translate3d(0, ${y}px, 0)`
          })
        })
      }

      this.handleScroll()
      window.addEventListener("scroll", this.handleScroll, { passive: true })
      window.addEventListener("resize", this.handleScroll)
    },

    destroyed() {
      if (this.raf) window.cancelAnimationFrame(this.raf)
      window.removeEventListener("scroll", this.handleScroll)
      window.removeEventListener("resize", this.handleScroll)
    },
  }

  Hooks.MarketingExampleScene = {
    mounted() {
      this.steps = Array.from(this.el.querySelectorAll("[data-example-step]"))
      this.jumps = Array.from(this.el.querySelectorAll("[data-example-jump]"))
      this.handlers = []
      this.activeIndex = null

      if (this.steps.length === 0) return

      this.pushIndex = (index, options = {}) => {
        const { scroll = false } = options
        const nextIndex = Math.max(0, Math.min(this.steps.length - 1, index))

        if (this.activeIndex !== nextIndex) {
          this.activeIndex = nextIndex
          this.pushEvent("set_example_index", { index: nextIndex })
        }

        if (scroll) {
          const step = this.steps[nextIndex]
          if (step) {
            step.scrollIntoView({
              behavior: reducedMotionPreferred() ? "auto" : "smooth",
              block: "start",
            })
          }
        }
      }

      this.jumps.forEach((jump) => {
        const index = Number(jump.dataset.exampleIndex)
        const clickHandler = () => this.pushIndex(index, { scroll: true })
        const keyHandler = (event) => {
          if (event.key !== "Enter" && event.key !== " ") return
          event.preventDefault()
          this.pushIndex(index, { scroll: true })
        }

        jump.addEventListener("click", clickHandler)
        jump.addEventListener("keydown", keyHandler)
        this.handlers.push({ element: jump, clickHandler, keyHandler })
      })

      this.observer = new IntersectionObserver(
        (entries) => {
          const visible = entries
            .filter((entry) => entry.isIntersecting)
            .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0]

          if (!visible) return

          this.pushIndex(Number(visible.target.dataset.exampleIndex))
        },
        {
          root: null,
          rootMargin: "-42% 0px -42% 0px",
          threshold: [0.15, 0.3, 0.5, 0.7, 1],
        },
      )

      this.steps.forEach((step) => this.observer.observe(step))

      if (reducedMotionPreferred()) {
        this.pushIndex(0)
        return
      }

      this.pushIndex(0)
    },

    destroyed() {
      if (this.observer) this.observer.disconnect()

      this.handlers.forEach(({ element, clickHandler, keyHandler }) => {
        element.removeEventListener("click", clickHandler)
        element.removeEventListener("keydown", keyHandler)
      })
    },
  }

  Hooks.MarketingStickyScene = {
    mounted() {
      this.steps = Array.from(this.el.querySelectorAll("[data-story-step]"))
      this.panels = Array.from(this.el.querySelectorAll("[data-story-panel]"))
      this.progressFill = this.el.querySelector("[data-story-progress-fill]")
      this.interactionHandlers = []

      if (this.steps.length === 0 || this.panels.length === 0) return

      this.activate = (index, options = {}) => {
        const { scroll = false } = options
        const ratio = this.steps.length > 1 ? index / (this.steps.length - 1) : 1

        this.steps.forEach((step) => {
          step.classList.toggle("is-active", Number(step.dataset.storyIndex) === index)
        })

        this.panels.forEach((panel) => {
          panel.classList.toggle("is-active", Number(panel.dataset.storyIndex) === index)
        })

        if (this.progressFill) {
          this.progressFill.style.transform = `scaleX(${ratio})`
        }

        if (scroll) {
          const step = this.steps[index]
          if (step) {
            step.scrollIntoView({
              behavior: reducedMotionPreferred() ? "auto" : "smooth",
              block: "center",
            })
          }
        }
      }

      this.steps.forEach((step) => {
        const index = Number(step.dataset.storyIndex)
        const clickHandler = () => this.activate(index, { scroll: true })
        const keyHandler = (event) => {
          if (event.key !== "Enter" && event.key !== " ") return
          event.preventDefault()
          this.activate(index, { scroll: true })
        }

        step.addEventListener("click", clickHandler)
        step.addEventListener("keydown", keyHandler)
        this.interactionHandlers.push({ step, clickHandler, keyHandler })
      })

      if (reducedMotionPreferred() || typeof IntersectionObserver !== "function") {
        this.activate(0)
        return
      }

      this.observer = new IntersectionObserver(
        (entries) => {
          const visible = entries
            .filter((entry) => entry.isIntersecting)
            .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0]

          if (!visible) return
          this.activate(Number(visible.target.dataset.storyIndex))
        },
        { threshold: [0.35, 0.55, 0.75], rootMargin: "-10% 0px -20% 0px" },
      )

      this.steps.forEach((step) => this.observer.observe(step))
      this.activate(0)
    },

    destroyed() {
      if (this.observer) this.observer.disconnect()
      this.interactionHandlers.forEach(({ step, clickHandler, keyHandler }) => {
        step.removeEventListener("click", clickHandler)
        step.removeEventListener("keydown", keyHandler)
      })
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
