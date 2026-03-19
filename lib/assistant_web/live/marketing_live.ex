defmodule AssistantWeb.MarketingLive do
  use AssistantWeb, :live_view

  import AssistantWeb.Components.MarketingPage, only: [marketing_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    signed_in? = match?(%{settings_user: %{}} = _scope, socket.assigns[:current_scope])

    socket =
      socket
      |> assign(:signed_in?, signed_in?)
      |> assign(:primary_cta_href, primary_cta_href(signed_in?))
      |> assign(:nav_app_href, nav_app_href(signed_in?))
      |> assign(:nav_app_label, nav_app_label(signed_in?))
      |> assign(:enterprise_contact_href, enterprise_contact_href())
      |> assign(:self_hosted_repo_href, self_hosted_repo_href())
      |> assign(:hero_video_src, hero_video_src())
      |> assign(:hero_video_poster_src, hero_video_poster_src())
      |> assign(:example_scenarios, example_scenarios())
      |> assign(:connectors, connectors())
      |> assign(:feature_cards, feature_cards())
      |> assign(:faq_items, faq_items())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.marketing_page
        signed_in?={@signed_in?}
        primary_cta_href={@primary_cta_href}
        nav_app_href={@nav_app_href}
        nav_app_label={@nav_app_label}
        enterprise_contact_href={@enterprise_contact_href}
        self_hosted_repo_href={@self_hosted_repo_href}
        hero_video_src={@hero_video_src}
        hero_video_poster_src={@hero_video_poster_src}
        example_scenarios={@example_scenarios}
        connectors={@connectors}
        feature_cards={@feature_cards}
        faq_items={@faq_items}
      />
    </Layouts.app>
    """
  end

  defp primary_cta_href(true), do: ~p"/workspace"
  defp primary_cta_href(false), do: ~p"/settings_users/log-in"

  defp nav_app_href(true), do: ~p"/workspace"
  defp nav_app_href(false), do: ~p"/settings_users/log-in"

  defp nav_app_label(true), do: "Open App"
  defp nav_app_label(false), do: "Log In"

  defp enterprise_contact_href do
    "mailto:profsynapse@synapticlabs.ai?subject=Synaptic%20Assistant%20Enterprise"
  end

  defp self_hosted_repo_href do
    "https://github.com/ProfSynapse/Synaptic-Assistant"
  end

  defp hero_video_src, do: "/videos/landing-loop-web.mp4"
  defp hero_video_poster_src, do: "/videos/landing-loop-poster.jpg"

  defp example_scenarios do
    [
      %{
        title: "Answer from real business context",
        body:
          "Ask a question once and get an answer grounded in synced files, past work, and the latest customer context.",
        chips: ["Business context", "Synced files", "Memory"],
        channel_label: "Workspace",
        thread_label: "Renewal thread",
        outcome: "Answers grounded in the latest account history, docs, and retained context.",
        empty_title: "Starts in the workspace with live account context.",
        empty_body: "The agent can pull CRM history, synced docs, and memory before it answers.",
        messages: [
          %{
            type: :message,
            role: :user,
            actor: "USER",
            time: "09:14",
            source_channel: "in_app",
            source_label: "In App",
            content: "What changed in the Acme renewal since last quarter?"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "09:14",
            source_channel: "in_app",
            source_label: "In App",
            content: "Checking the account record, latest renewal deck, and prior plan."
          },
          %{
            type: :tool,
            name: "HubSpot",
            detail: "Loaded renewal record, stakeholder changes, and deal notes.",
            time: "09:14",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Drive Search",
            detail: "Opened the latest renewal deck and pricing memo.",
            time: "09:14",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Memory",
            detail: "Recalled the last renewal plan and open support escalations.",
            time: "09:15",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "09:15",
            source_channel: "in_app",
            source_label: "In App",
            streaming: true,
            content:
              "Pricing moved up 8%, legal added a security addendum, and the customer asked for phased rollout support. I pulled the exact changes and linked the source notes."
          }
        ]
      },
      %{
        title: "Carry the thread across channels",
        body:
          "Start in chat, continue in the app, and keep the same context, files, and memory without rebuilding the prompt.",
        chips: ["Slack", "Workspace", "Shared context"],
        channel_label: "Slack",
        thread_label: "#launch-ops",
        outcome: "The same agent follows the work wherever the conversation moves.",
        empty_title: "Starts in Slack and keeps the same working thread.",
        empty_body:
          "The agent carries context from chat into the workspace instead of starting over.",
        messages: [
          %{
            type: :message,
            role: :user,
            actor: "USER",
            time: "14:02",
            source_channel: "slack",
            source_label: "Slack",
            content: "Can you prep the customer recap for tomorrow's QBR?"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "14:02",
            source_channel: "slack",
            source_label: "Slack",
            content: "On it. Pulling the latest account context and last QBR structure."
          },
          %{
            type: :tool,
            name: "Slack Thread",
            detail: "Linked the original request to the active workspace thread.",
            time: "14:02",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Workspace Memory",
            detail: "Loaded the last QBR recap format and open account risks.",
            time: "14:03",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Drive Notes",
            detail: "Pulled the latest usage notes and decision log for the account.",
            time: "14:03",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "14:03",
            source_channel: "in_app",
            source_label: "In App",
            streaming: true,
            content:
              "Draft is ready. I pulled the latest usage notes, open risks, and decision log so you can pick this back up in the workspace without restarting."
          }
        ]
      },
      %{
        title: "Take action across your systems",
        body:
          "Use one agent to review source material, update the system of record, and draft the next move.",
        chips: ["Transcript review", "CRM update", "Email draft"],
        channel_label: "Workspace",
        thread_label: "Post-call follow-up",
        outcome: "Move from conversation to clean records and ready-to-send output.",
        empty_title: "Starts with a post-call task and turns into real work.",
        empty_body:
          "The agent reviews the conversation, updates the CRM, and drafts the next move.",
        messages: [
          %{
            type: :message,
            role: :user,
            actor: "USER",
            time: "11:27",
            source_channel: "in_app",
            source_label: "In App",
            content:
              "Review the call transcript, update the account record in HubSpot, then draft me a follow-up email."
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "11:27",
            source_channel: "in_app",
            source_label: "In App",
            content:
              "On it. Reviewing the transcript, updating HubSpot, and drafting the follow-up."
          },
          %{
            type: :tool,
            name: "Transcript Analyzer",
            detail: "Captured objections, expansion target, follow-up date, and new stakeholder.",
            time: "11:27",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "HubSpot",
            detail: "Updated account notes, next step, and owner fields.",
            time: "11:28",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Email Draft",
            detail: "Prepared the follow-up with pricing answers and meeting options.",
            time: "11:28",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "11:28",
            source_channel: "in_app",
            source_label: "In App",
            streaming: true,
            content:
              "HubSpot is updated with the new stakeholder, expansion target, and follow-up date. I also drafted the email with the pricing answer and next meeting options."
          }
        ]
      },
      %{
        title: "Keep control with approvals",
        body:
          "When the work crosses a line that matters, the assistant can stop, package the work, and wait for a human.",
        chips: ["Approvals", "Policies", "Guardrails"],
        channel_label: "Google Chat",
        thread_label: "Approval gate",
        outcome: "Automation where it helps, human review where it matters.",
        empty_title: "Starts in Google Chat and runs until a controlled step.",
        empty_body:
          "The agent prepares the work, checks policy, and pauses only where review matters.",
        messages: [
          %{
            type: :message,
            role: :user,
            actor: "USER",
            time: "16:41",
            source_channel: "google_chat",
            source_label: "Google Chat",
            content: "Send the final customer summary to the account team."
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "16:41",
            source_channel: "google_chat",
            source_label: "Google Chat",
            content: "Preparing the summary package now. I’ll stop if the send needs review."
          },
          %{
            type: :tool,
            name: "Summary Builder",
            detail: "Compiled the customer recap and supporting pull quotes.",
            time: "16:41",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Policy Check",
            detail: "Flagged the pricing section as approval-sensitive.",
            time: "16:42",
            status: :done,
            status_label: "Done"
          },
          %{
            type: :tool,
            name: "Outbound Send",
            detail: "Held at the approval gate before delivery.",
            time: "16:42",
            status: :running,
            status_label: "Waiting"
          },
          %{
            type: :message,
            role: :assistant,
            actor: "SYNAPTIC",
            time: "16:42",
            source_channel: "google_chat",
            source_label: "Google Chat",
            streaming: true,
            content:
              "Ready to send. Waiting on approval because the pricing section changed after the last review."
          }
        ]
      }
    ]
  end

  defp connectors do
    [
      %{
        name: "Google Workspace",
        icon_path: "/images/apps/google.svg",
        summary: "Drive, Gmail, Calendar, and docs in working context."
      },
      %{
        name: "Microsoft",
        icon_path: "/images/apps/microsoft.svg",
        summary: "Bring Microsoft files and workflows into the same assistant."
      },
      %{
        name: "Box",
        icon_path: "/images/apps/box.svg",
        summary: "Retain shared files without export-and-upload loops."
      },
      %{
        name: "Slack",
        icon_path: "/images/apps/slack.svg",
        summary: "Answer inside channels while keeping workspace continuity."
      },
      %{
        name: "Discord",
        icon_path: "/images/apps/discord.svg",
        summary: "Support community and team workflows from the same system."
      },
      %{
        name: "Telegram",
        icon_path: "/images/apps/telegram.svg",
        summary: "Keep external chat surfaces tied to the same assistant memory."
      },
      %{
        name: "Google Chat",
        icon_path: "/images/apps/google-chat.svg",
        summary: "Work directly inside Google Chat spaces with shared context."
      },
      %{
        name: "HubSpot",
        icon_path: "/images/apps/hubspot.svg",
        summary: "Pull CRM context into conversations and follow-up workflows."
      }
    ]
  end

  defp feature_cards do
    [
      %{
        icon_name: "hero-chat-bubble-left-right",
        title: "Chat From Anywhere",
        body: "Work in the app, Slack, Telegram, or Google Chat without restarting the thread."
      },
      %{
        icon_name: "hero-command-line",
        title: "Use Real Tools",
        body:
          "Search files, update records, review transcripts, and draft the next move across connected systems."
      },
      %{
        icon_name: "hero-circle-stack",
        title: "Business Context Built In",
        body:
          "Pull from synced files, CRM history, and workspace context instead of starting from a blank prompt."
      },
      %{
        icon_name: "hero-cpu-chip",
        title: "Memory That Persists",
        body: "Keep what matters across conversations so the agent gets more useful over time."
      },
      %{
        icon_name: "hero-bolt",
        title: "Bring Your Own AI",
        body:
          "Use OpenRouter or OpenAI as the model layer while Synaptic handles context, memory, and orchestration."
      },
      %{
        icon_name: "hero-shield-check",
        title: "Controls For Real Teams",
        body:
          "Encrypted credentials, connector controls, and approval gates for actions that should stop for review."
      }
    ]
  end

  defp faq_items do
    [
      %{
        question: "Can I self-host Synaptic Assistant?",
        answer:
          "Yes. Synaptic Assistant is available under FSL-1.1-ALv2, which allows internal use, research, education, and other permitted non-competing use. If you need rights beyond those FSL terms, contact us."
      },
      %{
        question: "Do I bring my own model access?",
        answer:
          "Yes. Synaptic Assistant Cloud is built around your own model access while we handle sync, memory, orchestration, approvals, and workflow control."
      },
      %{
        question: "What is the difference between Cloud and self-hosted?",
        answer:
          "Cloud is the managed version with hosted infrastructure, storage billing, and commercial support. Self-hosted gives you the codebase and operational control under the FSL license."
      },
      %{
        question: "What counts toward storage?",
        answer:
          "Stored synced file content, retained transcript content, and memory content all count toward storage. Paid overage is based on monthly average retained storage, not peak usage."
      },
      %{
        question: "What happens at the free limit?",
        answer:
          "Free workspaces stop taking on new retained storage once they hit 25 MB. You can upgrade to Pro to continue syncing and retaining new workspace context."
      },
      %{
        question: "Which connectors are included on free?",
        answer:
          "Free includes Google, Microsoft, and Box. Pro unlocks the full connector set and paid storage overage above the included amount."
      }
    ]
  end
end
