defmodule AssistantWeb.Components.MarketingPage do
  @moduledoc false

  use AssistantWeb, :html

  attr :signed_in?, :boolean, required: true
  attr :primary_cta_href, :string, required: true
  attr :nav_app_href, :string, required: true
  attr :nav_app_label, :string, required: true
  attr :enterprise_contact_href, :string, required: true
  attr :example_scenarios, :list, required: true
  attr :faq_items, :list, required: true

  def marketing_page(assigns) do
    ~H"""
    <div id="marketing-page" class="sa-cloud-page" phx-hook="MarketingReveal">
      <header id="marketing-nav-shell" class="sa-cloud-nav-shell" phx-hook="MarketingNav">
        <div class="sa-cloud-nav">
          <a href="#top" class="sa-cloud-brand">
            <img src="/images/aperture.png" alt="Synaptic Assistant" class="sa-cloud-brand-mark" />
            <span>Synaptic Assistant</span>
          </a>

          <nav class="sa-cloud-nav-links" aria-label="Marketing">
            <a href="#examples">Examples</a>
            <a href="#integrations">Integrations</a>
            <a href="#pricing">Pricing</a>
            <a href="#faq">FAQ</a>
          </nav>

          <div class="sa-cloud-nav-actions">
            <div class="sa-cloud-socials" aria-label="Synaptic Labs links">
              <a
                href="https://www.synapticlabs.ai"
                class="sa-cloud-social-link"
                target="_blank"
                rel="noreferrer"
                aria-label="Synaptic Labs website"
                title="Synaptic Labs website"
              >
                <.icon name="hero-globe-alt" class="h-4 w-4" />
              </a>
              <a
                href="https://www.linkedin.com/company/synaptic-labs/"
                class="sa-cloud-social-link"
                target="_blank"
                rel="noreferrer"
                aria-label="Synaptic Labs on LinkedIn"
                title="Synaptic Labs on LinkedIn"
              >
                <.icon name="hero-briefcase" class="h-4 w-4" />
              </a>
              <a
                href="https://youtube.com/@synapticlabs"
                class="sa-cloud-social-link"
                target="_blank"
                rel="noreferrer"
                aria-label="Synaptic Labs on YouTube"
                title="Synaptic Labs on YouTube"
              >
                <.icon name="hero-play-circle" class="h-4 w-4" />
              </a>
              <a
                href="https://github.com/ProfSynapse/Synaptic-Assistant"
                class="sa-cloud-social-link"
                target="_blank"
                rel="noreferrer"
                aria-label="Synaptic Assistant on GitHub"
                title="Synaptic Assistant on GitHub"
              >
                <.icon name="hero-code-bracket-square" class="h-4 w-4" />
              </a>
            </div>

            <.link navigate={@nav_app_href} class="sa-cloud-nav-link">
              {@nav_app_label}
            </.link>
          </div>
        </div>
      </header>

      <section id="top" class="sa-cloud-hero">
        <div class="sa-cloud-hero-content" data-reveal>
          <p class="sa-cloud-kicker">Synaptic Assistant Cloud</p>
          <h1>One assistant, wherever work happens.</h1>
          <p class="sa-cloud-hero-copy">
            Access it from anywhere. Connect it to the tools you already use. Keep context,
            memory, and guarded workflows in one place.
          </p>

          <div class="sa-cloud-hero-actions">
            <.link navigate={@primary_cta_href} class="sa-btn">
              {if @signed_in?, do: "Open Workspace", else: "Get Started"}
            </.link>
            <a href="#pricing" class="sa-btn secondary">See Pricing</a>
          </div>

          <div class="sa-cloud-hero-pills" aria-label="Key product ideas">
            <span class="sa-chip">Access from app and chat</span>
            <span class="sa-chip">Connected to your workspace</span>
            <span class="sa-chip">Approvals when it matters</span>
          </div>
        </div>

        <canvas id="hero-beaker" class="sa-hero-beaker" phx-hook="HeroBeaker"></canvas>
      </section>

      <section id="examples" class="sa-cloud-examples">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Examples</p>
          <h2>See how the assistant shows up in real work.</h2>
        </div>

        <div class="sa-carousel" id="example-carousel" phx-hook="ExampleCarousel">
          <button class="sa-carousel-arrow sa-carousel-prev" aria-label="Previous example">
            <.icon name="hero-chevron-left" class="h-5 w-5" />
          </button>

          <div class="sa-carousel-track">
            <article
              :for={{scenario, index} <- Enum.with_index(@example_scenarios)}
              class="sa-carousel-slide"
              data-index={index}
            >
              <div class="sa-carousel-card">
                <div class="sa-carousel-card-meta">
                  <span class="sa-cloud-example-index">0{index + 1}</span>
                  <h3>{scenario.title}</h3>
                  <p>{scenario.body}</p>
                  <div class="sa-chip-row">
                    <span :for={chip <- scenario.chips} class="sa-chip">{chip}</span>
                  </div>
                </div>

                <div class="sa-cloud-demo-shell">
                  <div class="sa-cloud-demo-topbar">
                    <span class="sa-cloud-demo-dots"><span></span><span></span><span></span></span>
                    <span class="sa-cloud-demo-title">{scenario.source}</span>
                  </div>
                  <div class="sa-cloud-demo-body">
                    <article class="sa-cloud-demo-bubble is-user" data-bubble>
                      <span class="sa-cloud-demo-label">Asked</span>
                      <p>{scenario.prompt}</p>
                    </article>
                    <article class="sa-cloud-demo-context" data-bubble>
                      <div class="sa-cloud-demo-context-head">
                        <span class="sa-cloud-demo-label">{scenario.context_label}</span>
                        <span class="sa-cloud-demo-source">{scenario.source}</span>
                      </div>
                      <p>{scenario.context_body}</p>
                    </article>
                    <article class="sa-cloud-demo-bubble is-assistant" data-bubble>
                      <span class="sa-cloud-demo-label">Synaptic</span>
                      <p>{scenario.response}</p>
                    </article>
                  </div>
                  <div class="sa-cloud-demo-foot">
                    <span class="sa-cloud-demo-foot-line"></span>
                    <p>{scenario.footnote}</p>
                  </div>
                </div>
              </div>
            </article>
          </div>

          <button class="sa-carousel-arrow sa-carousel-next" aria-label="Next example">
            <.icon name="hero-chevron-right" class="h-5 w-5" />
          </button>

          <div class="sa-carousel-dots">
            <button
              :for={{_scenario, index} <- Enum.with_index(@example_scenarios)}
              class="sa-carousel-dot"
              data-dot={index}
              aria-label={"Example #{index + 1}"}
            ></button>
          </div>
        </div>
      </section>

      <section id="integrations" class="sa-cloud-integrations" data-reveal>
        <div class="sa-cloud-section-head">
          <p class="sa-cloud-kicker">Integrations</p>
          <h2>Connect the tools your team already uses.</h2>
        </div>
        <div class="sa-integrations-strip">
          <div class="sa-integration-item">
            <img src="/images/apps/google.svg" alt="Google" class="sa-integration-logo" />
            <span>Google</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/microsoft.svg" alt="Microsoft" class="sa-integration-logo" />
            <span>Microsoft</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/box.svg" alt="Box" class="sa-integration-logo" />
            <span>Box</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/slack.svg" alt="Slack" class="sa-integration-logo" />
            <span>Slack</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/discord.svg" alt="Discord" class="sa-integration-logo" />
            <span>Discord</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/telegram.svg" alt="Telegram" class="sa-integration-logo" />
            <span>Telegram</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/google-chat.svg" alt="Google Chat" class="sa-integration-logo" />
            <span>Google Chat</span>
          </div>
          <div class="sa-integration-item">
            <img src="/images/apps/hubspot.svg" alt="HubSpot" class="sa-integration-logo" />
            <span>HubSpot</span>
          </div>
        </div>
      </section>

      <section id="pricing" class="sa-cloud-pricing">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Pricing</p>
          <h2>One simple paid plan, with storage that scales cleanly.</h2>
        </div>

        <div class="sa-cloud-pricing-grid">
          <article class="sa-cloud-price-card" data-reveal>
            <p class="sa-cloud-price-name">Free</p>
            <h3>25 MB</h3>
            <p>Start with the basics and upgrade when the workspace becomes real.</p>
            <ul class="sa-cloud-price-list">
              <li>Google, Microsoft, and Box</li>
              <li>No overage billing</li>
              <li>Upgrade when you hit the cap</li>
            </ul>
            <.link navigate={@primary_cta_href} class="sa-btn secondary">Get Started</.link>
          </article>

          <article class="sa-cloud-price-card is-featured" data-reveal>
            <p class="sa-cloud-price-name">Pro</p>
            <h3>$18<span>/user/mo</span></h3>
            <p>The core product with clear storage math.</p>
            <ul class="sa-cloud-price-list">
              <li>10 GB included per user</li>
              <li>$1 per GB-month over 10 GB</li>
              <li>Billed on monthly average storage</li>
              <li>All connectors</li>
            </ul>
            <.link navigate={@primary_cta_href} class="sa-btn">
              {if @signed_in?, do: "Open Workspace", else: "Get Started"}
            </.link>
          </article>

          <article class="sa-cloud-price-card" data-reveal>
            <p class="sa-cloud-price-name">Enterprise</p>
            <h3>Contact Us</h3>
            <p>For teams that need custom limits, SSO, and commercial support.</p>
            <ul class="sa-cloud-price-list">
              <li>SSO and admin controls</li>
              <li>Custom terms and limits</li>
              <li>Direct support</li>
            </ul>
            <a href={@enterprise_contact_href} class="sa-btn secondary">Contact Us</a>
          </article>
        </div>

        <p class="sa-cloud-pricing-note" data-reveal>
          Example: if a Pro user averages 12 GB stored during the month, only 2 GB is billed as overage.
        </p>
      </section>

      <section id="faq" class="sa-cloud-faq">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">FAQ</p>
          <h2>Short answers to the obvious questions.</h2>
        </div>

        <div class="sa-cloud-faq-list">
          <details :for={faq <- @faq_items} class="sa-cloud-faq-item" data-reveal>
            <summary>
              <span>{faq.question}</span>
              <.icon name="hero-chevron-down" class="h-4 w-4" />
            </summary>
            <p>{faq.answer}</p>
          </details>
        </div>
      </section>
    </div>
    """
  end
end
