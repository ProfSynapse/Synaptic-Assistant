defmodule AssistantWeb.Components.MarketingPage do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.WorkspaceFeed

  attr :signed_in?, :boolean, required: true
  attr :primary_cta_href, :string, required: true
  attr :nav_app_href, :string, required: true
  attr :nav_app_label, :string, required: true
  attr :enterprise_contact_href, :string, required: true
  attr :self_hosted_repo_href, :string, required: true
  attr :hero_video_src, :string, required: true
  attr :hero_video_poster_src, :string, required: true
  attr :example_scenarios, :list, required: true
  attr :connectors, :list, required: true
  attr :feature_cards, :list, required: true
  attr :faq_items, :list, required: true

  def marketing_page(assigns) do
    ~H"""
    <div id="marketing-page" class="sa-cloud-page" phx-hook="MarketingReveal">
      <header id="marketing-nav-shell" class="sa-cloud-nav-shell" phx-hook="MarketingNav">
        <div class="sa-cloud-nav">
          <a href="#overview" class="sa-cloud-brand">
            <img src="/images/aperture.png" alt="Synaptic Assistant" class="sa-cloud-brand-mark" />
            <span>Synaptic Assistant</span>
          </a>

          <nav class="sa-cloud-nav-links" aria-label="Marketing">
            <a href="#overview">Overview</a>
            <a href="#examples">Examples</a>
            <a href="#connectors">Connectors</a>
            <a href="#pricing">Pricing</a>
            <a href="#faq">FAQ</a>
          </nav>

          <div class="sa-cloud-nav-actions">
            <.link navigate={@nav_app_href} class="sa-cloud-nav-link">
              {@nav_app_label}
            </.link>
          </div>
        </div>
      </header>

      <section id="overview" class="sa-cloud-hero">
        <div class="sa-cloud-hero-grid">
          <div class="sa-cloud-hero-copy-wrap" data-reveal>
            <p class="sa-cloud-kicker">Synaptic Assistant Cloud</p>
            <h1>The last AI agent your business will ever need.</h1>
            <p class="sa-cloud-hero-copy">
              An assistant that takes action with your tools, accesses your business intelligence,
              and remembers what matters.
            </p>

            <div class="sa-cloud-hero-actions">
              <.link navigate={@primary_cta_href} class="sa-btn">
                {if @signed_in?, do: "Open Workspace", else: "Get Started"}
              </.link>
              <a href="#examples" class="sa-btn secondary">See Examples</a>
            </div>
          </div>

          <div class="sa-cloud-video-card" data-reveal>
            <div class="sa-cloud-video-frame">
              <video
                class="sa-cloud-video"
                autoplay
                muted
                loop
                playsinline
                preload="auto"
                poster={@hero_video_poster_src}
                aria-label="Synaptic Assistant product preview"
              >
                <source src={@hero_video_src} type="video/mp4" />
                <source src="/videos/only-icon-square.mp4" type="video/mp4" />
                <img src={@hero_video_poster_src} alt="Synaptic Assistant product preview" class="sa-cloud-video-fallback" />
              </video>
            </div>
          </div>
        </div>
      </section>

      <section id="examples" class="sa-cloud-examples">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Examples</p>
          <h2>See how the agent works across conversations, tools, and memory.</h2>
          <p>
            Each example shows the assistant using business context, taking action, and carrying the
            thread forward.
          </p>
        </div>

        <div class="sa-carousel" id="example-carousel" phx-hook="ExampleCarousel" data-reveal>
          <button class="sa-carousel-arrow sa-carousel-prev" aria-label="Previous example">
            <.icon name="hero-chevron-left-solid" class="h-5 w-5" />
          </button>

          <div class="sa-carousel-viewport">
            <article
              :for={{scenario, index} <- Enum.with_index(@example_scenarios)}
              class={["sa-carousel-slide", index == 0 && "is-active"]}
              data-index={index}
            >
              <section class="sa-workspace-feed-wrap sa-cloud-chat-shell">
                <div class="sa-cloud-chat-empty" data-empty-state>
                  <div class="sa-cloud-chat-empty-meta">
                    <p class="sa-cloud-chat-empty-kicker">{scenario.channel_label}</p>
                    <p class="sa-cloud-chat-empty-thread">{scenario.thread_label}</p>
                  </div>
                  <h4>{scenario.empty_title}</h4>
                  <p>{scenario.empty_body}</p>
                </div>

                <div class="sa-workspace-feed sa-cloud-chat-feed">
                  <WorkspaceFeed.workspace_feed_items
                    items={scenario.messages}
                    sequence={true}
                    context_open={true}
                  />
                </div>
              </section>
            </article>
          </div>

          <button class="sa-carousel-arrow sa-carousel-next" aria-label="Next example">
            <.icon name="hero-chevron-right" class="h-5 w-5" />
          </button>

          <div class="sa-carousel-dots" aria-label="Example slides">
            <button
              :for={{_scenario, index} <- Enum.with_index(@example_scenarios)}
              class={["sa-carousel-dot", index == 0 && "is-active"]}
              data-dot={index}
              aria-label={"Example #{index + 1}"}
            >
            </button>
          </div>
        </div>
      </section>

      <section id="connectors" class="sa-cloud-connectors">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Connectors</p>
          <h2>Bring in the systems your team already uses.</h2>
          <p>
            Files, chat surfaces, and downstream tools stay in the same orbit instead of becoming
            separate assistant silos.
          </p>
        </div>

        <div class="sa-cloud-marquee" data-reveal>
          <div class="sa-cloud-marquee-track">
            <article
              :for={{connector, index} <- Enum.with_index(@connectors ++ @connectors)}
              class="sa-cloud-connector-card"
              aria-hidden={if(index >= length(@connectors), do: "true", else: "false")}
            >
              <img src={connector.icon_path} alt={connector.name} class="sa-cloud-connector-icon" />
              <div>
                <h3>{connector.name}</h3>
                <p>{connector.summary}</p>
              </div>
            </article>
          </div>
        </div>
      </section>

      <section id="capabilities" class="sa-cloud-capabilities">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Capabilities</p>
          <h2>Everything the agent needs to do real work.</h2>
          <p>Channels, tools, context, memory, model choice, and controls in one system.</p>
        </div>

        <div class="sa-cloud-capability-grid">
          <article :for={card <- @feature_cards} class="sa-cloud-capability-card" data-reveal>
            <div class="sa-cloud-capability-card-head">
              <span class="sa-cloud-capability-icon-wrap">
                <.icon name={card.icon_name} class="h-5 w-5" />
              </span>
              <h3>{card.title}</h3>
            </div>
            <p>{card.body}</p>
          </article>
        </div>
      </section>

      <section id="pricing" class="sa-cloud-pricing">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">Pricing</p>
          <h2>Cloud when you want it, self-hosted when you need it.</h2>
          <p>Start free, move to managed cloud, or run Synaptic Assistant yourself under FSL.</p>
        </div>

        <div class="sa-cloud-pricing-grid">
          <article class="sa-cloud-price-card" data-reveal>
            <p class="sa-cloud-price-name">Free</p>
            <h3>25 MB</h3>
            <p>Enough to prove the workflow before you start retaining real workspace context.</p>
            <ul class="sa-cloud-price-list">
              <li>Google Workspace, Microsoft, and Box</li>
              <li>In-app assistant and retained context</li>
              <li>Upgrade when you hit the cap</li>
            </ul>
            <.link navigate={@primary_cta_href} class="sa-btn secondary">Start Free</.link>
          </article>

          <article class="sa-cloud-price-card is-featured" data-reveal>
            <p class="sa-cloud-price-name">Pro</p>
            <h3>$18<span>/user/mo</span></h3>
            <p>The full product, all connectors, and storage that scales in a way finance can read.</p>
            <ul class="sa-cloud-price-list">
              <li>10 GB included per user</li>
              <li>$1 per GB-month above 10 GB</li>
              <li>Billed on monthly average retained storage</li>
              <li>All chat and workflow connectors</li>
            </ul>
            <.link navigate={@primary_cta_href} class="sa-btn">
              {if @signed_in?, do: "Open Workspace", else: "Get Started"}
            </.link>
          </article>

          <article class="sa-cloud-price-card" data-reveal>
            <p class="sa-cloud-price-name">Enterprise</p>
            <h3>Contact Us</h3>
            <p>For teams that need SSO, custom limits, managed rollout, or contract support.</p>
            <ul class="sa-cloud-price-list">
              <li>SSO and admin controls</li>
              <li>Custom retention and policy options</li>
              <li>Direct support and commercial terms</li>
            </ul>
            <a href={@enterprise_contact_href} class="sa-btn secondary">Contact Us</a>
          </article>

          <article class="sa-cloud-price-card" data-reveal>
            <p class="sa-cloud-price-name">Self-Hosted</p>
            <h3>Source Available</h3>
            <p>Run Synaptic Assistant on your own infrastructure under FSL-1.1-ALv2.</p>
            <ul class="sa-cloud-price-list">
              <li>Deploy on your own servers</li>
              <li>Internal and other permitted non-competing use</li>
              <li>Competing commercial rights require separate terms</li>
            </ul>
            <a href={@self_hosted_repo_href} class="sa-btn secondary" target="_blank" rel="noreferrer">
              View Repo
            </a>
          </article>
        </div>

        <p class="sa-cloud-pricing-note" data-reveal>
          Example: if a Pro user averages 12 GB stored during the month, only 2 GB is billed as
          overage. Self-hosted use is available under FSL; see the repo for license terms.
        </p>
      </section>

      <section id="faq" class="sa-cloud-faq">
        <div class="sa-cloud-section-head" data-reveal>
          <p class="sa-cloud-kicker">FAQ</p>
          <h2>Short answers to the questions people ask before they connect anything.</h2>
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
