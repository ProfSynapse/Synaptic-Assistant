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
      |> assign(:example_scenarios, example_scenarios())
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
        example_scenarios={@example_scenarios}
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

  defp example_scenarios do
    [
      %{
        title: "Ask from the app",
        body:
          "Start in the workspace and pull together synced docs, prior decisions, and the current thread without rebuilding the prompt.",
        chips: ["Workspace", "Docs", "Memory"],
        source: "In App",
        prompt: "Summarize the launch brief, pricing notes, and open questions for sales.",
        context_label: "Connected context",
        context_body:
          "Google Drive docs, retained memory, and the last launch thread are already in scope.",
        response:
          "I drafted a concise sales summary and highlighted the one pricing paragraph that still needs review.",
        footnote: "Everything stays in one running thread."
      },
      %{
        title: "Ask from anywhere",
        body:
          "The same assistant can answer from Slack, Telegram, or other connected channels while keeping the same workspace context behind the scenes.",
        chips: ["Slack", "Telegram", "Google Chat"],
        source: "#launch-ops",
        prompt: "Can we send the customer update this afternoon?",
        context_label: "Channel continuity",
        context_body:
          "The assistant keeps the same synced files and memory even when the question starts in chat.",
        response:
          "The draft is ready, but the external send is paused until pricing changes are approved.",
        footnote: "One assistant across app and chat."
      },
      %{
        title: "Pull in what matters",
        body:
          "Synced workspace material becomes useful context instead of scattered tabs, exports, and one-off uploads.",
        chips: ["Google", "Microsoft", "Box"],
        source: "Synced Workspace",
        prompt: "Find the latest pricing memo and compare it to last week's launch brief.",
        context_label: "Synced files",
        context_body:
          "Docs are available as searchable working context, so answers stay grounded in the latest source material.",
        response:
          "I found the updated memo, compared it to the launch brief, and flagged the one paragraph that changed.",
        footnote: "Connected to the files your team already uses."
      },
      %{
        title: "Keep control with approvals",
        body:
          "When the work crosses a line that matters, the assistant can stop and wait for a human instead of acting on its own.",
        chips: ["Approvals", "Policies", "Guardrails"],
        source: "Approval Gate",
        prompt: "Send the final customer summary to the account team.",
        context_label: "Guarded action",
        context_body:
          "High-impact sends can pause for review while the assistant still prepares the work around them.",
        response:
          "Ready to send. Waiting on approval because the pricing section changed after the last review.",
        footnote: "Automation where it helps. Humans where it matters."
      }
    ]
  end

  defp faq_items do
    [
      %{
        question: "Do I bring my own model access?",
        answer:
          "Yes. Synaptic Assistant Cloud is built around your own model access while we handle sync, memory, orchestration, approvals, and workflow control."
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
