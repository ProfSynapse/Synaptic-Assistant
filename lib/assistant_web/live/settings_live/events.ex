defmodule AssistantWeb.SettingsLive.Events do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, push_navigate: 2, redirect: 2]

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUserAllowlistEntry
  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.Billing
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Registry
  alias Assistant.Integrations.OpenAI
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive, as: GoogleDrive
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Integrations.Telegram.AccountLink
  alias Assistant.MemoryExplorer
  alias Assistant.MemoryGraph
  alias Assistant.ModelCatalog
  alias Assistant.ModelDefaults
  alias Assistant.OrchestratorSystemPrompt
  alias Assistant.SettingsUserConnectorStates
  alias Assistant.SkillPermissions
  alias Assistant.SpendingLimits
  alias Assistant.Storage
  alias Assistant.Storage.Source
  alias Assistant.Sync.StorageBridge
  alias Assistant.Transcripts
  alias Assistant.Workflows
  alias AssistantWeb.SettingsLive.Context
  alias AssistantWeb.SettingsLive.Data
  alias AssistantWeb.SettingsLive.Loaders
  alias AssistantWeb.SettingsLive.Profile
  alias AssistantWeb.SettingsUserAuth
  alias AssistantWeb.SettingsLive.PolicyClient

  require Logger

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("switch_admin_tab", %{"tab" => tab}, socket)
      when tab in ~w(integrations models users policies) do
    is_admin = socket.assigns.current_scope.admin?

    if tab != "integrations" and not is_admin do
      {:noreply, socket}
    else
      socket = assign(socket, :admin_tab, tab)

      socket =
        if tab == "policies" do
          Loaders.load_admin_policies(socket)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_event("set_policy_preset", %{"preset" => preset}, socket) do
    socket =
      case PolicyClient.apply_preset(socket.assigns[:current_scope], preset) do
        {:ok, _} ->
          socket
          |> assign(:policy_preset, preset)
          |> Loaders.load_admin_policies()
          |> put_flash(:info, "#{String.capitalize(preset)} preset applied.")

        {:error, :not_available} ->
          put_flash(socket, :error, "Policy presets are not available yet.")

        _ ->
          put_flash(socket, :error, "Unable to save policy preset.")
      end

    {:noreply, socket}
  end

  def handle_event("resolve_approval", %{"id" => id, "effect" => effect}, socket) do
    socket =
      case PolicyClient.resolve_approval(Context.current_settings_user(socket), id, effect) do
        {:ok, _} ->
          socket
          |> Loaders.load_approvals()
          |> put_flash(:info, "Approval recorded.")

        {:error, :not_available} ->
          put_flash(socket, :error, "Approvals are not available yet.")

        _ ->
          put_flash(socket, :error, "Unable to resolve approval.")
      end

    {:noreply, socket}
  end

  def handle_event("start_add_user", _params, socket) do
    blank_form =
      %SettingsUserAllowlistEntry{}
      |> Accounts.change_settings_user_allowlist_entry(%{
        active: true,
        is_admin: false,
        scopes: []
      })
      |> to_form(as: "allowlist_entry")

    {:noreply,
     socket
     |> assign(:creating_new_user, true)
     |> assign(:allowlist_form, blank_form)}
  end

  def handle_event("toggle_workflow_enabled", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case Workflows.set_enabled(name, enabled?) do
      {:ok, _workflow} ->
        {:noreply, Loaders.reload_workflows(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle workflow: #{inspect(reason)}")}
    end
  end

  def handle_event("new_workflow", _params, socket) do
    case Workflows.create_workflow() do
      {:ok, workflow} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created workflow: #{workflow.name}")
         |> push_navigate(to: "/settings/workflows/#{workflow.name}/edit")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create workflow: #{inspect(reason)}")}
    end
  end

  def handle_event("duplicate_workflow", %{"name" => name}, socket) do
    case Workflows.duplicate(name) do
      {:ok, copied} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created copy: #{copied.name}")
         |> Loaders.reload_workflows()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to duplicate workflow: #{inspect(reason)}")}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:model_modal_open, false)}
  end

  def handle_event("toggle_integration", %{"group" => group, "enabled" => enabled}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      case Registry.enabled_key_for_group(group) do
        nil ->
          {:noreply, put_flash(socket, :error, "Unknown integration group.")}

        enabled_key ->
          admin_id = socket.assigns.current_scope.settings_user.id

          case maybe_prepare_integration_toggle(group, enabled, admin_id) do
            :ok ->
              :ok

            {:error, _reason} ->
              :error
          end
          |> case do
            :error ->
              {:noreply, put_flash(socket, :error, "Unable to toggle integration.")}

            :ok ->
              case IntegrationSettings.put(enabled_key, enabled, admin_id) do
                {:ok, _setting} ->
                  {:noreply, reload_integration_settings(socket)}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Unable to toggle integration.")}
              end
          end
      end
    end
  end

  def handle_event("generate_telegram_connect_link", _params, socket) do
    {:noreply, generate_telegram_connect_link(socket)}
  end

  def handle_event("refresh_telegram_link_status", _params, socket) do
    {:noreply,
     socket
     |> Loaders.load_app_detail_settings(socket.assigns.current_app)
     |> clear_telegram_link_assigns_if_connected()}
  end

  def handle_event("disconnect_telegram", _params, socket) do
    Context.with_settings_user(socket, fn settings_user ->
      user_id =
        case settings_user do
          %{user_id: value} when is_binary(value) -> value
          _ -> nil
        end

      case AccountLink.disconnect_user(user_id) do
        {:ok, _count} ->
          {:noreply,
           socket
           |> assign(:telegram_identity, nil)
           |> clear_telegram_link_assigns()
           |> put_flash(:info, "Telegram account disconnected.")}
      end
    end)
  end

  def handle_event("save_integration", %{"key" => key, "value" => value}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      unless Registry.known_key?(key) do
        {:noreply, put_flash(socket, :error, "Unknown integration key.")}
      else
        if not key_allowed_for_current_admin_integration?(socket, key) do
          {:noreply, put_flash(socket, :error, "Invalid integration key for this page.")}
        else
          value = String.trim(value)

          if value == "" do
            {:noreply, put_flash(socket, :error, "Value cannot be blank.")}
          else
            admin_id = socket.assigns.current_scope.settings_user.id

            case save_integration_setting(key, value, admin_id, socket) do
              {:ok, _setting} ->
                {:noreply,
                 socket
                 |> maybe_generate_telegram_connect_link_after_save(key, value)
                 |> maybe_put_saved_integration_flash(key)
                 |> maybe_reload_integration_settings_after_save(key)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Unable to save integration setting.")}
            end
          end
        end
      end
    end
  end

  def handle_event("connect_google", _params, socket) do
    case Context.current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      settings_user ->
        case Context.ensure_linked_user(settings_user) do
          {:ok, user_id} ->
            case MagicLink.generate(user_id, "settings", %{}) do
              {:ok, %{token: raw_token}} ->
                {:noreply,
                 push_event(socket, "open_oauth_popup", %{
                   url: "/auth/google/start?token=#{raw_token}"
                 })}

              {:error, :rate_limited} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Too many authorization attempts. Please wait a few minutes."
                 )}

              {:error, _reason} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Failed to start Google authorization. Please try again."
                 )}
            end

          {:error, reason} ->
            Logger.error("connect_google: ensure_linked_user failed", reason: inspect(reason))

            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to prepare your account for Google authorization. Please try again."
             )}
        end
    end
  end

  def handle_event("disconnect_google", _params, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
      case TokenStore.get_google_token(user_id) do
        {:ok, oauth_token} ->
          case OAuth.revoke_token(oauth_token.access_token) do
            :ok -> :ok
            {:error, _reason} -> :ok
          end

        {:error, :not_connected} ->
          :ok
      end

      TokenStore.delete_google_token(user_id)

      {:noreply,
       socket
       |> assign(:google_connected, false)
       |> assign(:google_email, nil)
       |> put_flash(:info, "Google Workspace disconnected.")}
    end)
  end

  def handle_event("disconnect_openrouter", _params, socket) do
    Context.with_settings_user(socket, fn settings_user ->
      Accounts.delete_openrouter_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openrouter_connected, false)
       |> assign(:openrouter_key_form_open, false)
       |> assign(:openrouter_key_form, api_key_form(:openrouter_key))
       |> put_flash(:info, "OpenRouter disconnected.")}
    end)
  end

  def handle_event("connect_openrouter", _params, socket) do
    {:noreply, redirect(socket, to: "/settings_users/auth/openrouter")}
  end

  def handle_event("toggle_openrouter_key_form", _params, socket) do
    {:noreply,
     assign(socket, :openrouter_key_form_open, !socket.assigns.openrouter_key_form_open)}
  end

  def handle_event(
        "save_openrouter_api_key",
        %{"openrouter_key" => %{"api_key" => api_key}},
        socket
      ) do
    normalized_key = api_key |> to_string() |> String.trim()

    cond do
      normalized_key == "" ->
        {:noreply, put_flash(socket, :error, "Enter an OpenRouter API key.")}

      true ->
        Context.with_settings_user(socket, fn settings_user ->
          case OpenRouter.validate_api_key(normalized_key) do
            :ok ->
              case Accounts.save_openrouter_api_key(settings_user, normalized_key) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> assign(:openrouter_connected, true)
                   |> assign(:openrouter_key_form_open, false)
                   |> assign(:openrouter_key_form, api_key_form(:openrouter_key))
                   |> put_flash(:info, "OpenRouter connected and validated.")}

                {:error, _changeset} ->
                  {:noreply, put_flash(socket, :error, "Failed to save your OpenRouter key.")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "OpenRouter key validation failed.")}
          end
        end)
    end
  end

  def handle_event("connect_openai", _params, socket) do
    {:noreply,
     push_event(socket, "open_oauth_popup", %{
       url: "/settings_users/auth/openai?popup=1&flow=device",
       name: "openai_oauth"
     })}
  end

  def handle_event("disconnect_openai", _params, socket) do
    Context.with_settings_user(socket, fn settings_user ->
      Accounts.delete_openai_api_key(settings_user)

      {:noreply,
       socket
       |> assign(:openai_connected, false)
       |> assign(:openai_key_form_open, false)
       |> assign(:openai_key_form, api_key_form(:openai_key))
       |> put_flash(:info, "OpenAI disconnected.")}
    end)
  end

  def handle_event("toggle_openai_key_form", _params, socket) do
    {:noreply, assign(socket, :openai_key_form_open, !socket.assigns.openai_key_form_open)}
  end

  def handle_event("save_openai_api_key", %{"openai_key" => %{"api_key" => api_key}}, socket) do
    normalized_key = api_key |> to_string() |> String.trim()

    cond do
      normalized_key == "" ->
        {:noreply, put_flash(socket, :error, "Enter an OpenAI API key.")}

      true ->
        Context.with_settings_user(socket, fn settings_user ->
          case OpenAI.validate_api_key(normalized_key) do
            :ok ->
              case Accounts.save_openai_api_key(settings_user, normalized_key) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> assign(:openai_connected, true)
                   |> assign(:openai_key_form_open, false)
                   |> assign(:openai_key_form, api_key_form(:openai_key))
                   |> put_flash(:info, "OpenAI connected and validated.")}

                {:error, _changeset} ->
                  {:noreply, put_flash(socket, :error, "Failed to save your OpenAI key.")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "OpenAI key validation failed.")}
          end
        end)
    end
  end

  def handle_event("refresh_storage_sources", _params, socket) do
    refreshed = refresh_storage_sources(socket)

    flash =
      case refreshed.assigns.available_storage_sources do
        sources when is_list(sources) ->
          put_flash(refreshed, :info, "Discovered #{length(sources)} source(s).")

        _ ->
          put_flash(refreshed, :error, "Failed to fetch sources from Google.")
      end

    {:noreply, flash}
  end

  def handle_event("toggle_storage_source_access", %{"id" => id, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case ensure_storage_source_for_access(socket, %{"id" => id}, enabled?) do
      {:ok, source, socket} ->
        access_token =
          case GoogleAuth.user_token(source.user_id) do
            {:ok, token} -> token
            _ -> nil
          end

        case StorageBridge.reconcile_source(source.user_id, source.source_id,
               access_token: access_token
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> reload_storage_picker()
             |> refresh_selected_source()}

          {:error, reason} ->
            {:noreply,
             socket
             |> reload_storage_picker()
             |> refresh_selected_source()
             |> put_flash(:error, "Drive sync bridge failed: #{inspect(reason)}")}
        end

      {:error, :not_found, socket} ->
        {:noreply, put_flash(socket, :error, "Source not found.")}

      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, _reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle source.")}
    end
  end

  def handle_event("toggle_storage_source_access", params, socket) do
    enabled? = Map.get(params, "enabled") == "true"

    case ensure_storage_source_for_access(socket, params, enabled?) do
      {:ok, _source, socket} ->
        {:noreply,
         socket
         |> reload_storage_picker()
         |> refresh_selected_source()}

      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, _reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle source.")}
    end
  end

  def handle_event("open_file_picker", params, socket) do
    with {:ok, source, socket} <- ensure_storage_source_for_access(socket, params, :preserve),
         socket <- assign(socket, :file_picker_error, nil),
         {:ok, socket} <- load_file_picker_root(socket, source) do
      {:noreply,
       socket
       |> assign(:file_picker_open, true)
       |> assign(:file_picker_selected_source, source_to_picker_assign(source))
       |> seed_file_picker_draft(source)
       |> refresh_selected_source()}
    else
      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, reason, socket} ->
        {:noreply,
         socket
         |> assign(:file_picker_error, drive_tree_error_message(reason))
         |> put_flash(:error, "Failed to load source contents.")}
    end
  end

  def handle_event("close_file_picker", _params, socket) do
    {:noreply, reset_file_picker(socket)}
  end

  def handle_event("expand_file_picker_node", %{"node_key" => node_key}, socket) do
    node = socket.assigns.file_picker_nodes[node_key]
    expanded = socket.assigns.file_picker_expanded || MapSet.new()

    cond do
      is_nil(node) or node.node_type != "container" ->
        {:noreply, socket}

      MapSet.member?(expanded, node_key) ->
        {:noreply, assign(socket, :file_picker_expanded, MapSet.delete(expanded, node_key))}

      node.children_loaded? ->
        {:noreply, assign(socket, :file_picker_expanded, MapSet.put(expanded, node_key))}

      true ->
        socket =
          assign(
            socket,
            :file_picker_loading_nodes,
            MapSet.put(socket.assigns.file_picker_loading_nodes, node_key)
          )

        case load_file_picker_children(socket, node) do
          {:ok, socket} ->
            {:noreply,
             socket
             |> assign(
               :file_picker_loading_nodes,
               MapSet.delete(socket.assigns.file_picker_loading_nodes, node_key)
             )
             |> assign(
               :file_picker_expanded,
               MapSet.put(socket.assigns.file_picker_expanded, node_key)
             )
             |> assign(:file_picker_error, nil)}

          {:error, reason, socket} ->
            {:noreply,
             socket
             |> assign(
               :file_picker_loading_nodes,
               MapSet.delete(socket.assigns.file_picker_loading_nodes, node_key)
             )
             |> assign(:file_picker_error, drive_tree_error_message(reason))
             |> put_flash(:error, "Failed to load folder contents.")}
        end
    end
  end

  def handle_event("toggle_file_picker_node", %{"node_key" => node_key}, socket) do
    with %{source_id: _source_id} = selected_source when not is_nil(selected_source) <-
           socket.assigns[:file_picker_selected_source],
         node when not is_nil(node) <- socket.assigns.file_picker_nodes[node_key] do
      {:noreply, update_file_picker_draft(socket, selected_source, node)}
    else
      nil ->
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update file access.")}
    end
  end

  def handle_event("load_more_file_picker_children", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_file_picker", _params, socket) do
    with %{source_id: source_id} = selected_source when not is_nil(selected_source) <-
           socket.assigns[:file_picker_selected_source],
         user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, access_token} <- GoogleAuth.user_token(user_id),
         :ok <-
           persist_file_picker_draft(
             user_id,
             access_token,
             source_id,
             socket.assigns.file_picker_nodes,
             socket.assigns.file_picker_pending_ops || []
           ) do
      case StorageBridge.reconcile_source(user_id, source_id, access_token: access_token) do
        {:ok, _} ->
          {:noreply,
           socket
           |> reload_storage_picker()
           |> refresh_selected_source()
           |> reset_file_picker()
           |> put_flash(:info, "Drive access updated.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> reload_storage_picker()
           |> refresh_selected_source()
           |> put_flash(:error, "Drive sync bridge failed: #{inspect(reason)}")}
      end
    else
      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, drive_tree_error_message(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_model_modal", params, socket) do
    if socket.assigns.current_scope.settings_user.is_admin do
      query =
        params
        |> Map.get("query", socket.assigns[:model_library_query] || "")
        |> to_string()
        |> String.trim()

      socket =
        socket
        |> assign(:model_modal_open, true)
        |> assign(:model_library_query, query)
        |> assign(:model_library_form, to_form(%{"q" => query}, as: :model_library))
        |> load_model_library()

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Only admins can manage the model catalog.")}
    end
  end

  def handle_event("close_model_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:model_modal_open, false)
     |> assign(:model_library_error, nil)}
  end

  def handle_event("search_model_library", %{"model_library" => %{"q" => query}}, socket) do
    normalized_query = query |> to_string() |> String.trim()

    {:noreply,
     socket
     |> assign(:model_library_query, normalized_query)
     |> assign(:model_library_form, to_form(%{"q" => normalized_query}, as: :model_library))
     |> apply_model_library_filter()}
  end

  def handle_event("filter_active_models", %{"active_models" => params}, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    provider =
      params |> Map.get("provider", "all") |> to_string() |> String.trim() |> String.downcase()

    provider_options =
      socket.assigns[:active_model_provider_options] || [{"All providers", "all"}]

    allowed_providers = provider_options |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    normalized_provider =
      if MapSet.member?(allowed_providers, provider), do: provider, else: "all"

    all_models = socket.assigns[:active_model_all_models] || []

    {:noreply,
     socket
     |> assign(:active_model_query, query)
     |> assign(:active_model_provider, normalized_provider)
     |> assign(
       :active_model_filter_form,
       to_form(%{"q" => query, "provider" => normalized_provider}, as: :active_models)
     )
     |> assign(:models, Loaders.filter_active_models(all_models, query, normalized_provider))}
  end

  def handle_event("change_model_defaults", %{"defaults" => params}, socket) do
    {:noreply, persist_model_defaults(socket, params)}
  end

  def handle_event("refresh_model_library", _params, socket) do
    {:noreply, load_model_library(socket)}
  end

  def handle_event("save_model", %{"model" => params}, socket) do
    if socket.assigns.current_scope.settings_user.is_admin do
      case ModelCatalog.add_model(params) do
        {:ok, _model} ->
          {:noreply,
           socket
           |> assign(:model_modal_open, false)
           |> Loaders.load_models()
           |> put_flash(:info, "Model catalog saved")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save model: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only admins can manage the model catalog.")}
    end
  end

  def handle_event("add_model_from_library", params, socket) do
    if socket.assigns.current_scope.settings_user.is_admin do
      attrs = %{
        "id" => Map.get(params, "id", ""),
        "name" => Map.get(params, "name", ""),
        "input_cost" => Map.get(params, "input_cost", "n/a"),
        "output_cost" => Map.get(params, "output_cost", "n/a"),
        "max_context_tokens" => Map.get(params, "max_context_tokens", "n/a")
      }

      case ModelCatalog.add_model(attrs) do
        {:ok, _model} ->
          {:noreply,
           socket
           |> Loaders.load_models()
           |> maybe_reload_model_library()
           |> put_flash(:info, "Model added to your catalog")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to add model: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only admins can manage the model catalog.")}
    end
  end

  def handle_event("remove_model_from_catalog", %{"id" => model_id}, socket) do
    if socket.assigns.current_scope.settings_user.is_admin do
      case ModelCatalog.remove_model(model_id) do
        :ok ->
          {:noreply,
           socket
           |> Loaders.load_models()
           |> maybe_reload_model_library()
           |> put_flash(:info, "Model removed from your catalog")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to remove model: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only admins can manage the model catalog.")}
    end
  end

  def handle_event("save_model_defaults", %{"defaults" => params}, socket) do
    {:noreply, persist_model_defaults(socket, params, flash?: true)}
  end

  def handle_event("toggle_connector", %{"group" => group, "enabled" => enabled} = params, socket) do
    enabled? = enabled == "true"
    app_id = Map.get(params, "app_id", "")
    app = Data.find_app(app_id)

    Context.with_settings_user(socket, fn settings_user ->
      case Context.ensure_linked_user(settings_user) do
        {:ok, user_id} ->
          case maybe_require_telegram_setup(app, user_id, enabled?) do
            :ok ->
              case SettingsUserConnectorStates.set_enabled_for_user(user_id, group, enabled?) do
                {:ok, _state} ->
                  {:noreply,
                   socket
                   |> reload_current_user_scope()
                   |> Loaders.load_connector_states()
                   |> maybe_reload_current_app_detail()
                   |> put_flash(:info, connector_toggle_flash(app, enabled?))}

                {:error, _changeset} ->
                  {:noreply, put_flash(socket, :error, "Unable to update connector state.")}
              end

            {:redirect, reason} ->
              {:noreply,
               socket
               |> put_flash(:info, reason)
               |> push_navigate(to: "/settings/apps/telegram")}
          end

        {:error, reason} ->
          Logger.error("toggle_connector: ensure_linked_user failed", reason: inspect(reason))
          {:noreply, put_flash(socket, :error, "Unable to prepare your account.")}
      end
    end)
  end

  def handle_event("toggle_personal_skill", %{"skill" => skill, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    integration_group =
      socket.assigns[:current_app] && socket.assigns.current_app.integration_group

    Context.with_settings_user(socket, fn settings_user ->
      case Context.ensure_linked_user(settings_user) do
        {:ok, user_id} ->
          case SkillPermissions.set_enabled_for_user(user_id, skill, enabled?) do
            {:ok, _override} ->
              {:noreply,
               socket
               |> reload_current_user_scope()
               |> Loaders.load_personal_skill_permissions(integration_group: integration_group)
               |> put_flash(:info, "#{SkillPermissions.skill_label(skill)} updated")}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Failed to update personal tool access.")}
          end

        {:error, reason} ->
          Logger.error("toggle_personal_skill: ensure_linked_user failed",
            reason: inspect(reason)
          )

          {:noreply, put_flash(socket, :error, "Unable to prepare your account.")}
      end
    end)
  end

  def handle_event("search_help", %{"help" => %{"q" => query}}, socket) do
    {:noreply, assign(socket, :help_query, query)}
  end

  # --- Admin event handlers (ported from AdminLive) ---

  def handle_event("claim_bootstrap_admin", _params, socket) do
    case Accounts.bootstrap_admin_access(socket.assigns.current_scope.settings_user) do
      {:ok, _settings_user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Admin access claimed.")
         |> reload_current_user_scope()
         |> Loaders.load_admin()}

      {:error, :bootstrap_closed} ->
        {:noreply,
         socket
         |> put_flash(:error, "Admin bootstrap is no longer available.")
         |> push_navigate(to: "/settings")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to claim admin access.")}
    end
  end

  def handle_event("validate_allowlist_entry", %{"allowlist_entry" => params}, socket) do
    form =
      %SettingsUserAllowlistEntry{}
      |> Accounts.change_settings_user_allowlist_entry(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "allowlist_entry")

    {:noreply, assign(socket, :allowlist_form, form)}
  end

  def handle_event("save_allowlist_entry", %{"allowlist_entry" => params}, socket) do
    if socket.assigns.creating_new_user do
      attrs = %{
        email: Map.get(params, "email"),
        full_name: Map.get(params, "full_name"),
        is_admin: Map.get(params, "is_admin") == "true",
        access_scopes: List.wrap(Map.get(params, "scopes", []))
      }

      actor = socket.assigns.current_scope.settings_user

      case Billing.ensure_billing_account(actor) do
        {:ok, {_, billing_account}} ->
          case Accounts.create_settings_user_from_admin(attrs,
                 billing_account_id: billing_account.id
               ) do
            {:ok, settings_user} ->
              socket = maybe_save_spending_limit(socket, settings_user.id, params)

              {:noreply,
               socket
               |> assign(:creating_new_user, false)
               |> put_flash(:info, "User created successfully.")
               |> reload_current_user_scope()
               |> Loaders.load_admin()}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:noreply,
               assign(socket, :allowlist_form, to_form(changeset, as: "allowlist_entry"))}

            {:error, :billing_account_conflict} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "That user already belongs to a different billing workspace."
               )}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Unable to create user.")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to load the workspace billing account.")}
      end
    else
      case Accounts.upsert_settings_user_allowlist_entry(
             params,
             socket.assigns.current_scope.settings_user
           ) do
        {:ok, _entry} ->
          {:noreply,
           socket
           |> assign(:creating_new_user, false)
           |> put_flash(:info, "User added successfully.")
           |> reload_current_user_scope()
           |> Loaders.load_admin()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :allowlist_form, to_form(changeset, as: "allowlist_entry"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to save allow list entry.")}
      end
    end
  end

  def handle_event("reset_allowlist_form", _params, socket) do
    blank_form =
      %SettingsUserAllowlistEntry{}
      |> Accounts.change_settings_user_allowlist_entry(%{
        active: true,
        is_admin: false,
        scopes: []
      })
      |> to_form(as: "allowlist_entry")

    {:noreply, assign(socket, :allowlist_form, blank_form)}
  end

  def handle_event("edit_allowlist_entry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.allowlist_entries, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Allow list entry not found.")}

      entry ->
        {:noreply,
         assign(
           socket,
           :allowlist_form,
           to_form(Accounts.change_settings_user_allowlist_entry(entry), as: "allowlist_entry")
         )}
    end
  end

  def handle_event("toggle_allowlist_entry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.allowlist_entries, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Allow list entry not found.")}

      entry ->
        params = %{
          email: entry.email,
          active: !entry.active,
          is_admin: entry.is_admin,
          scopes: entry.scopes,
          notes: entry.notes
        }

        case Accounts.upsert_settings_user_allowlist_entry(
               params,
               socket.assigns.current_scope.settings_user
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Allow list entry updated.")
             |> reload_current_user_scope()
             |> Loaders.load_admin()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to update allow list entry.")}
        end
    end
  end

  def handle_event("send_recovery_link", %{"id" => id}, socket) do
    with %{} = user <- Enum.find(socket.assigns.admin_settings_users, &(&1.id == id)),
         {:ok, _email} <-
           Accounts.admin_send_recovery_link(user, &login_url/1) do
      {:noreply, put_flash(socket, :info, "Recovery magic link sent to #{user.email}.")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "User is not currently allow-listed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to send recovery link.")}
    end
  end

  def handle_event("force_password_reset", %{"id" => id}, socket) do
    with %{} = user <- Enum.find(socket.assigns.admin_settings_users, &(&1.id == id)),
         {:ok, _updated_user, expired_tokens, _email} <-
           Accounts.admin_force_password_reset(user, &login_url/1) do
      SettingsUserAuth.disconnect_sessions(expired_tokens)

      {:noreply, put_flash(socket, :info, "Password reset initiated for #{user.email}.")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "User is not currently allow-listed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to force password reset.")}
    end
  end

  def handle_event("delete_integration", %{"key" => key}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      unless Registry.known_key?(key) do
        {:noreply, put_flash(socket, :error, "Unknown integration key.")}
      else
        if not key_allowed_for_current_admin_integration?(socket, key) do
          {:noreply, put_flash(socket, :error, "Invalid integration key for this page.")}
        else
          case IntegrationSettings.delete(String.to_existing_atom(key)) do
            {:ok, _} ->
              {:noreply,
               socket
               |> maybe_clear_deleted_telegram_setting(key)
               |> put_flash(:info, "Integration setting reverted to environment variable.")
               |> reload_integration_settings()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Unable to delete integration setting.")}
          end
        end
      end
    end
  end

  # --- Admin user card management handlers ---

  def handle_event("search_admin_users", %{"query" => query}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      normalized = query |> to_string() |> String.trim()
      all_users = socket.assigns[:admin_users_with_keys] || []

      {:noreply,
       socket
       |> assign(:admin_user_search, normalized)
       |> assign(:filtered_admin_users, Loaders.filter_admin_users(all_users, normalized))}
    end
  end

  def handle_event("edit_admin_user", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      case Loaders.admin_user_detail(user_id) do
        {:ok, user} ->
          {:noreply, assign(socket, :current_admin_user, user)}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}
      end
    end
  end

  def handle_event("back_to_admin_users", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_admin_user, nil)
     |> assign(:creating_new_user, false)}
  end

  def handle_event(
        "save_workspace_billing",
        %{"user_id" => user_id, "workspace_billing" => params},
        socket
      ) do
    settings_user = socket.assigns.current_scope.settings_user

    unless settings_user.is_admin and Billing.manages_billing?(settings_user) do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      with {:ok, user} <- Loaders.admin_user_detail(user_id),
           %{billing_account: %{id: billing_account_id}} <- user,
           {:ok, _billing_account} <-
             Billing.update_billing_account_overrides(billing_account_id, params) do
        {:noreply,
         socket
         |> put_flash(:info, "Workspace billing updated.")
         |> Loaders.reload_admin_users()}
      else
        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          message =
            changeset.errors
            |> Keyword.keys()
            |> List.first()
            |> case do
              nil ->
                "Unable to update workspace billing."

              field ->
                "Unable to update workspace billing: #{Phoenix.Naming.humanize(field)} is invalid."
            end

          {:noreply, put_flash(socket, :error, message)}

        _ ->
          {:noreply, put_flash(socket, :error, "Unable to update workspace billing.")}
      end
    end
  end

  def handle_event("toggle_user_disabled", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      actor_id = socket.assigns.current_scope.settings_user.id

      case Accounts.toggle_user_disabled(user_id, actor_id) do
        {:ok, _user, expired_tokens} ->
          SettingsUserAuth.disconnect_sessions(expired_tokens)

          {:noreply,
           socket
           |> put_flash(:info, "User status updated.")
           |> Loaders.reload_admin_users()}

        {:error, :cannot_disable_self} ->
          {:noreply, put_flash(socket, :error, "You cannot disable your own account.")}

        {:error, :last_admin} ->
          {:noreply, put_flash(socket, :error, "Cannot disable the last active admin.")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to update user status.")}
      end
    end
  end

  def handle_event(
        "toggle_user_model_defaults_access",
        %{"id" => user_id, "enabled" => enabled},
        socket
      ) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      enabled? = enabled == "true"

      case Accounts.toggle_user_model_defaults_access(user_id, enabled?) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Model defaults access updated.")
           |> Loaders.reload_admin_users()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to update model defaults access.")}
      end
    end
  end

  def handle_event(
        "change_admin_user_model_defaults",
        %{"user_id" => user_id, "defaults" => params},
        socket
      ) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      {:noreply, persist_admin_user_model_defaults(socket, user_id, params)}
    end
  end

  def handle_event("apply_global_admin_user_model_defaults", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      {:noreply,
       persist_admin_user_model_defaults(socket, user_id, %{},
         flash: "User defaults reset to global defaults.",
         replace?: true
       )}
    end
  end

  def handle_event("delete_admin_user", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      actor_id = socket.assigns.current_scope.settings_user.id

      case Accounts.delete_settings_user(user_id, actor_id) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> assign(:current_admin_user, nil)
           |> put_flash(:info, "User deleted.")
           |> Loaders.reload_admin_users()}

        {:error, :cannot_delete_self} ->
          {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}

        {:error, :last_admin} ->
          {:noreply, put_flash(socket, :error, "Cannot delete the last active admin.")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to delete user.")}
      end
    end
  end

  def handle_event("toggle_admin_status", %{"id" => user_id, "is-admin" => is_admin}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      is_admin? = is_admin == "true"

      case Accounts.toggle_admin_status(user_id, is_admin?) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Admin status updated.")
           |> Loaders.reload_admin_users()}

        {:error, :last_admin} ->
          {:noreply, put_flash(socket, :error, "Cannot demote the last active admin.")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to update admin status.")}
      end
    end
  end

  def handle_event(
        "save_admin_user_openrouter_key",
        %{"user_id" => user_id, "api_key" => api_key},
        socket
      ) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      api_key = String.trim(api_key)

      if api_key == "" do
        {:noreply, put_flash(socket, :error, "API key cannot be blank.")}
      else
        case Accounts.admin_set_openrouter_key(user_id, api_key) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "OpenRouter API key saved.")
             |> Loaders.reload_admin_users()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to save API key.")}
        end
      end
    end
  end

  def handle_event("delete_admin_user_openrouter_key", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      case Accounts.admin_clear_openrouter_key(user_id) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "OpenRouter API key removed.")
           |> Loaders.reload_admin_users()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to remove API key.")}
      end
    end
  end

  def handle_event("save_spending_limit", %{"user_id" => user_id} = params, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      budget_dollars = params["budget_dollars"] |> to_string() |> String.trim()

      if budget_dollars == "" do
        SpendingLimits.delete_spending_limit(user_id)

        {:noreply,
         socket
         |> put_flash(:info, "Spending limit removed.")
         |> Loaders.reload_admin_users()}
      else
        attrs = %{
          budget_cents: parse_dollars_to_cents(budget_dollars),
          hard_cap: params["hard_cap"] == "true",
          warning_threshold: parse_int(params["warning_threshold"], 80)
        }

        case SpendingLimits.upsert_spending_limit(user_id, attrs) do
          {:ok, _limit} ->
            {:noreply,
             socket
             |> put_flash(:info, "Spending limit updated.")
             |> Loaders.reload_admin_users()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to save spending limit.")}
        end
      end
    end
  end

  def handle_event("remove_spending_limit", %{"id" => user_id}, socket) do
    unless socket.assigns.current_scope.settings_user.is_admin do
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    else
      SpendingLimits.delete_spending_limit(user_id)

      {:noreply,
       socket
       |> put_flash(:info, "Spending limit removed.")
       |> Loaders.reload_admin_users()}
    end
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    Profile.save_profile(socket, params, flash?: true)
  end

  def handle_event("dismiss_onboarding", _params, socket) do
    settings_user = Context.current_settings_user(socket)
    now = DateTime.utc_now(:second)

    case Accounts.update_settings_user_onboarding_dismissed(settings_user, now) do
      {:ok, _updated} ->
        {:noreply, assign(socket, :onboarding_dismissed?, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not dismiss checklist.")}
    end
  end

  def handle_event("autosave_profile", %{"profile" => params}, socket) do
    Profile.save_profile(socket, params, flash?: false)
  end

  def handle_event("autosave_orchestrator_prompt", %{"body" => body}, socket) do
    content = body |> to_string()
    socket = Profile.notify_autosave(socket, "saving", "Saving system instructions...")

    case OrchestratorSystemPrompt.save_prompt(content) do
      :ok ->
        {:noreply,
         socket
         |> assign(:orchestrator_prompt_text, content)
         |> assign(:orchestrator_prompt_html, Loaders.markdown_to_html(content))
         |> Profile.notify_autosave("saved", "All changes saved")}

      {:error, reason} ->
        {:noreply,
         socket
         |> Profile.notify_autosave("error", "Could not save system instructions")
         |> put_flash(:error, "Failed to save prompt: #{inspect(reason)}")}
    end
  end

  def handle_event("update_global_filters", %{"global" => params}, socket) do
    filters = normalize_graph_filters(params)

    socket =
      socket
      |> assign(:graph_filters, filters)
      |> assign(:graph_filters_form, to_form(filters, as: :global))
      |> assign(:selected_transcript, nil)
      |> assign(:selected_memory, nil)
      |> Loaders.load_memory_dashboard()

    {:noreply, push_event(socket, "render_graph", socket.assigns.graph_data)}
  end

  def handle_event("init_graph", _params, socket) do
    {:noreply, push_event(socket, "render_graph", socket.assigns.graph_data)}
  end

  def handle_event("expand_node", %{"node_id" => node_id}, socket) do
    graph_filters = socket.assigns.graph_filters || Data.blank_graph_filters()

    expanded_data =
      MemoryGraph.expand_node(socket.assigns[:current_scope], node_id, graph_filters)

    existing_data = socket.assigns.graph_data || %{nodes: [], links: []}
    existing_node_ids = socket.assigns.loaded_node_ids || MapSet.new()

    append_nodes =
      expanded_data.nodes
      |> Enum.reject(fn node -> MapSet.member?(existing_node_ids, Map.get(node, :id)) end)

    append_links = new_links(existing_data.links, expanded_data.links)

    graph_data = merge_graph_data(existing_data, %{nodes: append_nodes, links: append_links})

    loaded_node_ids =
      append_nodes
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reduce(existing_node_ids, &MapSet.put(&2, &1))

    socket =
      socket
      |> assign(:graph_data, graph_data)
      |> assign(:loaded_node_ids, loaded_node_ids)

    if append_nodes == [] and append_links == [] do
      {:noreply, socket}
    else
      {:noreply, push_event(socket, "append_graph", %{nodes: append_nodes, links: append_links})}
    end
  end

  def handle_event("filter_transcripts", %{"transcripts" => params}, socket) do
    filters = normalize_transcript_filters(params)

    {:noreply,
     socket
     |> assign(:transcript_filters, filters)
     |> assign(:transcript_filters_form, to_form(filters, as: :transcripts))
     |> assign(:selected_transcript, nil)
     |> Loaders.load_transcripts()}
  end

  def handle_event("view_transcript", %{"id" => id}, socket) do
    case Transcripts.get_transcript(id) do
      {:ok, transcript} ->
        {:noreply, assign(socket, :selected_transcript, transcript)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Transcript not found")}
    end
  end

  def handle_event("close_transcript", _params, socket) do
    {:noreply, assign(socket, :selected_transcript, nil)}
  end

  def handle_event("filter_memories", %{"memories" => params}, socket) do
    filters = normalize_memory_filters(params)

    {:noreply,
     socket
     |> assign(:memory_filters, filters)
     |> assign(:memory_filters_form, to_form(filters, as: :memories))
     |> assign(:selected_memory, nil)
     |> Loaders.load_memories()}
  end

  def handle_event("view_memory", %{"id" => id}, socket) do
    case MemoryExplorer.get_memory(id) do
      {:ok, memory} ->
        {:noreply, assign(socket, :selected_memory, memory)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Memory not found")}
    end
  end

  def handle_event("close_memory", _params, socket) do
    {:noreply, assign(socket, :selected_memory, nil)}
  end

  def handle_event("navigate_node", %{"kind" => "memory", "id" => id}, socket) do
    case MemoryExplorer.get_memory(id) do
      {:ok, memory} ->
        {:noreply, assign(socket, :selected_memory, memory)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Memory not found")}
    end
  end

  def handle_event("navigate_node", %{"kind" => "entity", "id" => id}, socket) do
    {:noreply, assign(socket, :selected_entity_id, id)}
  end

  def handle_event("navigate_node", _params, socket) do
    {:noreply, socket}
  end

  defp reload_storage_picker(socket) do
    socket
    |> Loaders.load_connected_storage_sources()
    |> Loaders.load_available_storage_sources()
    |> Loaders.load_storage_scopes()
  end

  defp refresh_storage_sources(socket) do
    socket = assign(socket, :storage_sources_loading, true)

    case Context.current_user_id(socket) do
      nil ->
        socket
        |> assign(:available_storage_sources, [])
        |> assign(:storage_sources_loading, false)

      user_id ->
        case Storage.list_provider_sources(user_id, "google_drive") do
          {:ok, sources} ->
            socket
            |> assign(:available_storage_sources, sources)
            |> assign(:storage_sources_loading, false)

          {:error, _reason} ->
            socket
            |> assign(:available_storage_sources, [])
            |> assign(:storage_sources_loading, false)
        end
    end
  end

  defp refresh_selected_source(socket) do
    case socket.assigns[:file_picker_selected_source] do
      nil ->
        socket

      selected_source ->
        refreshed =
          Enum.find(socket.assigns[:connected_storage_sources] || [], fn source ->
            source.source_type == selected_source.source_type and
              source.source_id == selected_source.source_id
          end)

        case refreshed do
          nil ->
            assign(socket, :file_picker_selected_source, %{
              selected_source
              | connected_id: nil,
                enabled: false
            })

          source ->
            assign(socket, :file_picker_selected_source, source_to_picker_assign(source))
        end
    end
  end

  defp source_to_picker_assign(source) do
    %{
      source_key: source_access_key(source.source_type, source.source_id),
      source_id: source.source_id,
      source_name: source.source_name,
      source_type: source.source_type,
      connected_id: source.id,
      enabled: source.enabled
    }
  end

  defp seed_file_picker_draft(socket, source) do
    source_scopes =
      socket.assigns.storage_scopes
      |> Enum.filter(&scope_in_source?(&1, source.source_id))
      |> Enum.reduce(%{}, fn scope, acc ->
        case file_picker_draft_scope_key(scope) do
          nil -> acc
          key -> Map.put(acc, key, draft_scope_from_storage_scope(scope))
        end
      end)

    socket
    |> assign(:file_picker_selection_draft, source_scopes)
    |> assign(:file_picker_pending_ops, [])
    |> assign(:file_picker_dirty, false)
  end

  defp reset_file_picker(socket) do
    socket
    |> assign(:file_picker_open, false)
    |> assign(:file_picker_selected_source, nil)
    |> assign(:file_picker_nodes, %{})
    |> assign(:file_picker_root_keys, [])
    |> assign(:file_picker_expanded, MapSet.new())
    |> assign(:file_picker_loading, false)
    |> assign(:file_picker_loading_nodes, MapSet.new())
    |> assign(:file_picker_error, nil)
    |> assign(:file_picker_selection_draft, %{})
    |> assign(:file_picker_pending_ops, [])
    |> assign(:file_picker_dirty, false)
    |> assign(:file_picker_continuations, %{})
  end

  defp ensure_storage_source_for_access(socket, %{"id" => id} = params, mode)
       when is_binary(id) and id != "" do
    case Storage.get_connected_source(id) do
      nil ->
        ensure_storage_source_for_access(socket, Map.delete(params, "id"), mode)

      source ->
        case mode do
          :preserve ->
            {:ok, source, socket}

          enabled? when is_boolean(enabled?) and source.enabled != enabled? ->
            case Storage.toggle_connected_source(id, enabled?) do
              {:ok, updated_source} -> {:ok, updated_source, socket}
              {:error, reason} -> {:error, reason, socket}
            end

          _ ->
            {:ok, source, socket}
        end
    end
  end

  defp ensure_storage_source_for_access(socket, params, mode) do
    case Context.current_settings_user(socket) do
      nil ->
        {:error, :not_connected, socket}

      settings_user ->
        with {:ok, user_id} <- Context.ensure_linked_user(settings_user),
             attrs <- source_attrs_from_params(params, mode),
             {:ok, source} <- Storage.connect_source(user_id, attrs) do
          {:ok, source, reload_current_user_scope(socket)}
        else
          {:error, reason} -> {:error, reason, socket}
        end
    end
  end

  defp source_attrs_from_params(params, mode) do
    source_id =
      params
      |> Map.get("source_id")
      |> normalize_source_id()

    source_type =
      case Map.get(params, "source_type") do
        "shared" -> "shared"
        "library" -> "library"
        "namespace" -> "namespace"
        _ when source_id == "personal" -> "personal"
        _ -> "shared"
      end

    enabled? =
      case mode do
        :preserve -> false
        value when is_boolean(value) -> value
      end

    %{
      provider: "google_drive",
      source_id: source_id,
      source_name:
        Map.get(
          params,
          "source_name",
          if(source_type == "personal", do: "My Drive", else: "Shared Drive")
        ),
      source_type: source_type,
      enabled: enabled?,
      capabilities: Storage.provider_capabilities("google_drive")
    }
  end

  defp load_file_picker_root(socket, source) do
    socket =
      socket
      |> assign(:file_picker_loading, true)
      |> assign(:file_picker_error, nil)
      |> assign(:file_picker_nodes, %{})
      |> assign(:file_picker_root_keys, [])
      |> assign(:file_picker_expanded, MapSet.new())
      |> assign(:file_picker_loading_nodes, MapSet.new())
      |> assign(:file_picker_continuations, %{})

    with user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, %{items: items}} <-
           Storage.list_children(
             user_id,
             "google_drive",
             source_to_provider_source(source),
             :root
           ) do
      {nodes, root_keys, continuations} = merge_file_picker_children(%{}, %{}, nil, items, nil)

      {:ok,
       socket
       |> assign(:file_picker_nodes, nodes)
       |> assign(:file_picker_root_keys, root_keys)
       |> assign(:file_picker_continuations, continuations)
       |> assign(:file_picker_loading, false)}
    else
      {:error, reason} ->
        {:error, reason, assign(socket, :file_picker_loading, false)}

      _ ->
        {:error, :not_connected, assign(socket, :file_picker_loading, false)}
    end
  end

  defp load_file_picker_children(socket, node) do
    with %{source_id: source_id, source_type: source_type} <-
           socket.assigns[:file_picker_selected_source],
         user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, %{items: items}} <-
           Storage.list_children(
             user_id,
             "google_drive",
             %Source{
               provider: :google_drive,
               source_id: source_id,
               source_type: source_type,
               label: socket.assigns.file_picker_selected_source.source_name,
               capabilities: Storage.provider_capabilities("google_drive")
             },
             node.node_id
           ) do
      {nodes, _child_keys, continuations} =
        merge_file_picker_children(
          socket.assigns.file_picker_nodes,
          socket.assigns.file_picker_continuations || %{},
          node.key,
          items,
          nil
        )

      {:ok,
       socket
       |> assign(:file_picker_nodes, nodes)
       |> assign(:file_picker_continuations, continuations)}
    else
      {:error, reason} -> {:error, reason, socket}
      _ -> {:error, :not_connected, socket}
    end
  end

  defp source_to_provider_source(source) do
    %Source{
      provider: :google_drive,
      source_id: source.source_id,
      source_type: source.source_type,
      label: source.source_name,
      capabilities: Storage.provider_capabilities("google_drive")
    }
  end

  defp merge_file_picker_children(nodes, continuations, parent_key, children, next_cursor) do
    Enum.reduce(children, {nodes, []}, fn child, {acc_nodes, child_keys} ->
      node_key = file_picker_node_key(child)
      existing = Map.get(acc_nodes, node_key, %{})
      container? = child.node_type == :container

      node =
        existing
        |> Map.merge(%{
          key: node_key,
          node_id: child.node_id,
          name: child.name,
          mime_type: child.mime_type,
          node_type: Atom.to_string(child.node_type),
          file_kind: child.file_kind,
          parent_key: parent_key
        })
        |> Map.put_new(:child_keys, [])
        |> Map.put(
          :children_loaded?,
          if(container?, do: Map.get(existing, :children_loaded?, false), else: true)
        )

      {Map.put(acc_nodes, node_key, node), child_keys ++ [node_key]}
    end)
    |> then(fn {updated_nodes, child_keys} ->
      nodes_with_parent =
        case parent_key do
          nil ->
            updated_nodes

          _ ->
            update_in(updated_nodes[parent_key], fn parent ->
              parent
              |> Map.put(:child_keys, child_keys)
              |> Map.put(:children_loaded?, true)
            end)
        end

      updated_continuations =
        case next_cursor do
          nil -> Map.delete(continuations, parent_key)
          cursor -> Map.put(continuations, parent_key, cursor)
        end

      {nodes_with_parent, child_keys, updated_continuations}
    end)
  end

  defp update_file_picker_draft(socket, selected_source, node) do
    draft_scopes = socket.assigns.file_picker_selection_draft || %{}
    tree_nodes = socket.assigns.file_picker_nodes || %{}

    {inherited_selected?, currently_selected?} =
      file_picker_selection_from_draft(draft_scopes, tree_nodes, node)

    desired_selected? = !currently_selected?

    updated_scopes =
      draft_scopes
      |> clear_loaded_descendant_draft_scopes(node, tree_nodes)
      |> persist_file_picker_draft_scope(
        selected_source.source_id,
        tree_nodes,
        node,
        inherited_selected?,
        desired_selected?
      )

    pending_ops = socket.assigns.file_picker_pending_ops || []

    socket
    |> assign(:file_picker_selection_draft, updated_scopes)
    |> assign(
      :file_picker_pending_ops,
      pending_ops ++ [%{node_key: node.key, desired_selected?: desired_selected?}]
    )
    |> assign(:file_picker_dirty, true)
  end

  defp maybe_clear_storage_descendant_scopes(_user_id, _access_token, _source_id, %{
         node_type: type
       })
       when type in ["file", "link"],
       do: :ok

  defp maybe_clear_storage_descendant_scopes(user_id, access_token, source_id, %{
         node_type: "container",
         node_id: folder_id
       }) do
    with {:ok, descendants} <-
           fetch_storage_subtree_descendants(access_token, source_id, folder_id) do
      _ =
        Storage.delete_scopes_in_targets(
          user_id,
          "google_drive",
          source_id,
          descendants.container_ids,
          descendants.file_ids
        )

      :ok
    end
  end

  defp persist_storage_explicit_scope(
         user_id,
         source_id,
         tree_nodes,
         node,
         existing_scope,
         inherited_selected?,
         desired_selected?
       ) do
    if desired_selected? == inherited_selected? do
      case existing_scope do
        nil -> :ok
        scope -> Storage.delete_scope(scope) |> ok_or_error()
      end
    else
      attrs =
        %{
          user_id: user_id,
          provider: "google_drive",
          source_id: source_id,
          access_level: "read_write",
          scope_effect: if(desired_selected?, do: "include", else: "exclude")
        }
        |> Map.merge(storage_scope_attrs(node, tree_nodes))

      case Storage.upsert_scope(attrs) do
        {:ok, _scope} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_file_picker_draft(_user_id, _access_token, _source_id, _tree_nodes, []), do: :ok

  defp persist_file_picker_draft(user_id, access_token, source_id, tree_nodes, operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      case persist_file_picker_operation(user_id, access_token, source_id, tree_nodes, operation) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_file_picker_operation(user_id, access_token, source_id, tree_nodes, operation) do
    case tree_nodes[operation.node_key] do
      nil ->
        :ok

      node ->
        scopes = Storage.list_scopes(user_id, provider: "google_drive", source_id: source_id)

        {inherited_selected?, _currently_selected?} =
          file_picker_selection_from_scopes(scopes, tree_nodes, node, source_id)

        explicit_scope = explicit_storage_scope_for_node(user_id, source_id, node)

        with :ok <- maybe_clear_storage_descendant_scopes(user_id, access_token, source_id, node),
             :ok <-
               persist_storage_explicit_scope(
                 user_id,
                 source_id,
                 tree_nodes,
                 node,
                 explicit_scope,
                 inherited_selected?,
                 operation.desired_selected?
               ) do
          :ok
        end
    end
  end

  defp storage_scope_attrs(%{node_type: "container", node_id: node_id, name: name}, _nodes) do
    %{
      node_id: node_id,
      node_type: "container",
      scope_type: Storage.container_scope_type(),
      label: name
    }
  end

  defp storage_scope_attrs(
         %{node_type: type, node_id: node_id, name: name, mime_type: mime_type} = node,
         nodes
       )
       when type in ["file", "link"] do
    %{
      node_id: node_id,
      parent_node_id: parent_container_id(node),
      node_type: "file",
      scope_type: Storage.file_scope_type(),
      label: name,
      file_kind: node.file_kind,
      mime_type: mime_type,
      provider_metadata: %{"parent_label" => node_parent_label(node, nodes)}
    }
  end

  defp explicit_storage_scope_for_node(user_id, source_id, %{
         node_type: "container",
         node_id: node_id
       }) do
    Storage.get_scope(user_id, "google_drive", source_id, node_id, Storage.container_scope_type())
  end

  defp explicit_storage_scope_for_node(user_id, source_id, %{node_type: type, node_id: node_id})
       when type in ["file", "link"] do
    Storage.get_scope(user_id, "google_drive", source_id, node_id, Storage.file_scope_type())
  end

  defp file_picker_selection_from_draft(draft_scopes, tree_nodes, node) do
    inherited_selected? =
      node_ancestor_chain(tree_nodes, node)
      |> Enum.reduce(false, fn ancestor, acc ->
        case draft_explicit_effect_for_tree_node(draft_scopes, ancestor) do
          "include" -> true
          "exclude" -> false
          nil -> acc
        end
      end)

    current_selected? =
      case draft_explicit_effect_for_tree_node(draft_scopes, node) do
        "include" -> true
        "exclude" -> false
        nil -> inherited_selected?
      end

    {inherited_selected?, current_selected?}
  end

  defp file_picker_selection_from_scopes(scopes, tree_nodes, node, source_id) do
    inherited_selected? =
      node_ancestor_chain(tree_nodes, node)
      |> Enum.reduce(false, fn ancestor, acc ->
        case explicit_effect_for_storage_tree_node(scopes, source_id, ancestor) do
          "include" -> true
          "exclude" -> false
          nil -> acc
        end
      end)

    current_selected? =
      case explicit_effect_for_storage_tree_node(scopes, source_id, node) do
        "include" -> true
        "exclude" -> false
        nil -> inherited_selected?
      end

    {inherited_selected?, current_selected?}
  end

  defp explicit_effect_for_storage_tree_node(scopes, source_id, %{
         node_type: "container",
         node_id: node_id
       }) do
    case Enum.find(
           scopes,
           &(&1.source_id == source_id and &1.scope_type == "container" and &1.node_id == node_id)
         ) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_effect_for_storage_tree_node(scopes, source_id, %{
         node_type: type,
         node_id: node_id
       })
       when type in ["file", "link"] do
    case Enum.find(
           scopes,
           &(&1.source_id == source_id and &1.scope_type == "file" and &1.node_id == node_id)
         ) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp persist_file_picker_draft_scope(
         draft_scopes,
         source_id,
         tree_nodes,
         node,
         inherited_selected?,
         desired_selected?
       ) do
    if desired_selected? == inherited_selected? do
      Map.delete(draft_scopes, node.key)
    else
      Map.put(
        draft_scopes,
        node.key,
        %{
          source_id: source_id,
          scope_effect: if(desired_selected?, do: "include", else: "exclude")
        }
        |> Map.merge(storage_scope_attrs(node, tree_nodes))
      )
    end
  end

  defp file_picker_draft_scope_key(%{scope_type: "container", node_id: node_id})
       when is_binary(node_id),
       do: "container:#{node_id}"

  defp file_picker_draft_scope_key(%{scope_type: "file", node_id: node_id})
       when is_binary(node_id),
       do: "file:#{node_id}"

  defp file_picker_draft_scope_key(_scope), do: nil

  defp draft_scope_from_storage_scope(scope) do
    %{
      source_id: scope.source_id,
      scope_type: scope.scope_type,
      scope_effect: scope.scope_effect,
      node_id: scope.node_id,
      parent_node_id: scope.parent_node_id,
      node_type: scope.node_type,
      label: scope.label,
      file_kind: scope.file_kind,
      mime_type: scope.mime_type,
      provider_metadata: scope.provider_metadata || %{}
    }
  end

  defp scope_in_source?(scope, source_id), do: scope.source_id == source_id

  defp fetch_storage_subtree_descendants(access_token, source_id, folder_id) do
    do_fetch_storage_subtree_descendants(
      access_token,
      source_id,
      [folder_id],
      MapSet.new(),
      MapSet.new()
    )
  end

  defp do_fetch_storage_subtree_descendants(
         _access_token,
         _source_id,
         [],
         container_ids,
         file_ids
       ) do
    {:ok, %{container_ids: MapSet.to_list(container_ids), file_ids: MapSet.to_list(file_ids)}}
  end

  defp do_fetch_storage_subtree_descendants(
         access_token,
         source_id,
         [folder_id | rest],
         container_ids,
         file_ids
       ) do
    with {:ok, children} <-
           list_drive_children(access_token, Storage.provider_source_id(source_id), folder_id) do
      {child_folders, child_files} = Enum.split_with(children, &drive_folder?(&1.mime_type))

      next_queue = rest ++ Enum.map(child_folders, & &1.id)
      next_container_ids = Enum.reduce(child_folders, container_ids, &MapSet.put(&2, &1.id))
      next_file_ids = Enum.reduce(child_files, file_ids, &MapSet.put(&2, &1.id))

      do_fetch_storage_subtree_descendants(
        access_token,
        source_id,
        next_queue,
        next_container_ids,
        next_file_ids
      )
    end
  end

  defp parent_container_id(%{parent_key: nil}), do: nil

  defp parent_container_id(%{parent_key: parent_key}) do
    case parent_key do
      "container:" <> folder_id -> folder_id
      _ -> nil
    end
  end

  defp node_parent_label(%{parent_key: nil, name: name}, _nodes), do: name

  defp node_parent_label(%{parent_key: parent_key, name: name}, nodes) do
    case Map.get(nodes, parent_key) do
      %{name: parent_name} -> parent_name
      _ -> name
    end
  end

  defp file_picker_node_key(%{node_type: :container, node_id: id}), do: "container:#{id}"
  defp file_picker_node_key(%{node_type: :link, node_id: id}), do: "link:#{id}"
  defp file_picker_node_key(%{node_id: id}), do: "file:#{id}"

  defp source_access_key("personal", _source_id), do: "personal"
  defp source_access_key(_source_type, source_id), do: "source:#{source_id}"

  defp normalize_source_id(""), do: "personal"
  defp normalize_source_id(nil), do: "personal"
  defp normalize_source_id(value), do: value

  defp ok_or_error({:ok, _value}), do: :ok
  defp ok_or_error({count, nil}) when is_integer(count), do: :ok
  defp ok_or_error(other), do: {:error, other}

  defp list_drive_children(access_token, drive_id, parent_id) do
    query = drive_children_query(drive_id, parent_id)

    case drive_module().list_files(access_token, query, drive_children_query_opts(drive_id)) do
      {:ok, files} -> {:ok, sort_drive_items(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp node_ancestor_chain(nodes, node) do
    do_node_ancestor_chain(nodes, node.parent_key, [])
  end

  defp do_node_ancestor_chain(_nodes, nil, acc), do: Enum.reverse(acc)

  defp do_node_ancestor_chain(nodes, parent_key, acc) do
    parent = Map.get(nodes, parent_key)

    case parent do
      nil -> Enum.reverse(acc)
      _ -> do_node_ancestor_chain(nodes, parent.parent_key, [parent | acc])
    end
  end

  defp draft_explicit_effect_for_tree_node(draft_scopes, %{key: key}) do
    case Map.get(draft_scopes, key) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp clear_loaded_descendant_draft_scopes(draft_scopes, %{node_type: "file"}, _tree_nodes),
    do: draft_scopes

  defp clear_loaded_descendant_draft_scopes(draft_scopes, node, tree_nodes) do
    loaded_descendant_node_keys(tree_nodes, node)
    |> Enum.reduce(draft_scopes, &Map.delete(&2, &1))
  end

  defp loaded_descendant_node_keys(tree_nodes, node) do
    (node.child_keys || [])
    |> Enum.flat_map(fn child_key ->
      case tree_nodes[child_key] do
        nil -> []
        child -> [child.key | loaded_descendant_node_keys(tree_nodes, child)]
      end
    end)
  end

  defp drive_children_query(nil, :root), do: "'root' in parents and trashed=false"

  defp drive_children_query(drive_id, :root) when is_binary(drive_id),
    do: "'#{drive_id}' in parents and trashed=false"

  defp drive_children_query(_drive_id, parent_id),
    do: "'#{parent_id}' in parents and trashed=false"

  defp drive_children_query_opts(nil) do
    [
      pageSize: 200,
      orderBy: "name",
      corpora: "user",
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
  end

  defp drive_children_query_opts(drive_id) do
    [
      pageSize: 200,
      orderBy: "name",
      corpora: "drive",
      driveId: drive_id,
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
  end

  defp sort_drive_items(items) do
    Enum.sort_by(items, fn item ->
      {
        if(drive_folder?(item.mime_type), do: 0, else: 1),
        String.downcase(item.name || "")
      }
    end)
  end

  defp drive_folder?("application/vnd.google-apps.folder"), do: true
  defp drive_folder?(_), do: false

  defp drive_tree_error_message(:not_connected), do: "Connect your Google account first."
  defp drive_tree_error_message(:not_found), do: "Drive item not found."
  defp drive_tree_error_message(_), do: "Unable to update Drive access."

  defp drive_module do
    Application.get_env(:assistant, :google_drive_module, GoogleDrive)
  end

  defp login_url(token) do
    AssistantWeb.Endpoint.url() <> "/settings_users/log-in/#{token}"
  end

  defp reload_current_user_scope(socket) do
    current_user = Accounts.get_settings_user!(socket.assigns.current_scope.settings_user.id)
    assign(socket, :current_scope, Assistant.Accounts.Scope.for_settings_user(current_user))
  end

  defp reload_integration_settings(socket) do
    section = socket.assigns[:section]
    current_app = socket.assigns[:current_app]
    current_admin_integration = socket.assigns[:current_admin_integration]

    cond do
      current_app != nil ->
        Loaders.load_app_detail_settings(socket, current_app)

      current_admin_integration != nil ->
        Loaders.load_admin_integration_settings(
          socket,
          current_admin_integration.integration_group
        )

      section == "admin" ->
        Loaders.load_admin(socket)

      section == "apps" ->
        socket
        |> Loaders.load_apps_integration_settings()
        |> Loaders.load_workspace_enabled_groups()
        |> Loaders.load_connector_states()
        |> Loaders.load_connection_status()

      true ->
        socket
    end
  end

  defp save_integration_setting("telegram_bot_token", value, admin_id, _socket) do
    with :ok <- ensure_telegram_webhook_secret(admin_id),
         {:ok, _enabled} <- IntegrationSettings.put(:telegram_enabled, "true", admin_id),
         {:ok, setting} <- IntegrationSettings.put(:telegram_bot_token, value, admin_id) do
      {:ok, setting}
    end
  end

  defp save_integration_setting(key, value, admin_id, _socket) do
    IntegrationSettings.put(String.to_existing_atom(key), value, admin_id)
  end

  defp maybe_prepare_integration_toggle("telegram", "true", admin_id) do
    ensure_telegram_webhook_secret(admin_id)
  end

  defp maybe_prepare_integration_toggle(_group, _enabled, _admin_id), do: :ok

  defp key_allowed_for_current_admin_integration?(socket, key) do
    case socket.assigns[:current_admin_integration] do
      nil ->
        true

      %{integration_group: integration_group} ->
        case Registry.definition_for_key(key) do
          %{group: ^integration_group} -> true
          _ -> false
        end
    end
  end

  defp maybe_reload_current_app_detail(socket) do
    case socket.assigns[:current_app] do
      nil -> socket
      app -> Loaders.load_app_detail_settings(socket, app)
    end
  end

  defp connector_toggle_flash(%{name: name}, true), do: "#{name} enabled."
  defp connector_toggle_flash(%{name: name}, false), do: "#{name} disabled."
  defp connector_toggle_flash(_, true), do: "Connector enabled."
  defp connector_toggle_flash(_, false), do: "Connector disabled."

  defp maybe_require_telegram_setup(%{id: "telegram"}, user_id, true) do
    cond do
      not telegram_bot_configured?() ->
        {:redirect, "Your admin must configure Telegram before you can enable it."}

      true ->
        case AccountLink.linked_identity_for_user(user_id) do
          {:ok, _identity} ->
            :ok

          {:error, :not_connected} ->
            {:redirect, "Finish Telegram setup in Settings before enabling it."}
        end
    end
  end

  defp maybe_require_telegram_setup(_app, _user_id, _enabled), do: :ok

  defp telegram_bot_configured? do
    case IntegrationSettings.get(:telegram_bot_token) do
      token when is_binary(token) -> String.trim(token) != ""
      _ -> false
    end
  end

  defp ensure_telegram_webhook_secret(admin_id) do
    case IntegrationSettings.get(:telegram_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        :ok

      _ ->
        case IntegrationSettings.put(:telegram_webhook_secret, random_secret(), admin_id) do
          {:ok, _setting} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_generate_telegram_connect_link_after_save(
         %{assigns: %{current_app: %{id: "telegram"}}} = socket,
         "telegram_bot_token",
         bot_token
       ) do
    generate_telegram_connect_link(socket, bot_token: bot_token)
  end

  defp maybe_generate_telegram_connect_link_after_save(socket, _key, _value), do: socket

  defp generate_telegram_connect_link(socket, opts \\ []) do
    Context.with_settings_user(socket, fn settings_user ->
      cond do
        socket.assigns[:telegram_identity] != nil ->
          {:noreply, put_flash(socket, :info, "Telegram is already linked to your account.")}

        (not socket.assigns[:telegram_bot_configured] and socket.assigns[:current_app]) &&
            socket.assigns.current_scope.settings_user.is_admin == false ->
          {:noreply,
           put_flash(socket, :error, "Your admin must configure the Telegram bot first.")}

        true ->
          case Context.ensure_linked_user(settings_user) do
            {:ok, user_id} ->
              updated_socket = reload_current_user_scope(socket)
              generate_telegram_connect_link_result(updated_socket, user_id, opts)

            {:error, reason} ->
              Logger.error("generate_telegram_connect_link: ensure_linked_user failed",
                reason: inspect(reason)
              )

              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Failed to prepare your account for Telegram linking. Please try again."
               )}
          end
      end
    end)
    |> case do
      {:noreply, updated_socket} -> updated_socket
    end
  end

  defp generate_telegram_connect_link_result(updated_socket, user_id, opts) do
    bot_token = Keyword.get(opts, :bot_token)

    case AccountLink.generate_connect_link(user_id, bot_token) do
      {:ok, %{url: url, bot_username: bot_username, expires_at: expires_at}} ->
        {:noreply,
         updated_socket
         |> assign(:telegram_connect_url, url)
         |> assign(:telegram_bot_username, bot_username)
         |> assign(:telegram_connect_expires_at, expires_at)
         |> put_flash(:info, "Open the Telegram link to connect your account.")}

      {:error, :bot_not_configured} ->
        {:noreply, put_flash(updated_socket, :error, "Save a Telegram bot token first.")}

      {:error, :bot_username_missing} ->
        {:noreply, put_flash(updated_socket, :error, "Telegram did not return a bot username.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           updated_socket,
           :error,
           "Telegram could not verify this bot token. Check the token and try again."
         )}
    end
  end

  defp clear_telegram_link_assigns(socket) do
    socket
    |> assign(:telegram_connect_url, nil)
    |> assign(:telegram_bot_username, nil)
    |> assign(:telegram_connect_expires_at, nil)
  end

  defp clear_telegram_link_assigns_if_connected(socket) do
    if socket.assigns[:telegram_identity] do
      clear_telegram_link_assigns(socket)
    else
      socket
    end
  end

  defp maybe_clear_deleted_telegram_setting(socket, key)
       when key in ["telegram_bot_token", "telegram_webhook_secret"] do
    clear_telegram_link_assigns(socket)
  end

  defp maybe_clear_deleted_telegram_setting(socket, _key), do: socket

  defp maybe_put_saved_integration_flash(
         %{assigns: %{current_app: %{id: "telegram"}}} = socket,
         "telegram_bot_token"
       ) do
    socket
  end

  defp maybe_put_saved_integration_flash(socket, _key) do
    put_flash(socket, :info, "Integration setting saved.")
  end

  defp maybe_reload_integration_settings_after_save(
         %{assigns: %{current_app: %{id: "telegram"}}} = socket,
         "telegram_bot_token"
       ) do
    socket
    |> assign(:telegram_bot_configured, true)
    |> assign(:telegram_enabled, true)
  end

  defp maybe_reload_integration_settings_after_save(socket, _key) do
    reload_integration_settings(socket)
  end

  defp random_secret do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp normalize_transcript_filters(params) when is_map(params) do
    %{
      "query" => Map.get(params, "query", "") |> to_string() |> String.trim(),
      "channel" => Map.get(params, "channel", "") |> to_string() |> String.trim(),
      "status" => Map.get(params, "status", "") |> to_string() |> String.trim(),
      "agent_type" => Map.get(params, "agent_type", "") |> to_string() |> String.trim()
    }
  end

  defp normalize_transcript_filters(_), do: Data.blank_transcript_filters()

  defp normalize_memory_filters(params) when is_map(params) do
    %{
      "query" => Map.get(params, "query", "") |> to_string() |> String.trim(),
      "category" => Map.get(params, "category", "") |> to_string() |> String.trim(),
      "source_type" => Map.get(params, "source_type", "") |> to_string() |> String.trim(),
      "tag" => Map.get(params, "tag", "") |> to_string() |> String.trim(),
      "source_conversation_id" =>
        Map.get(params, "source_conversation_id", "") |> to_string() |> String.trim()
    }
  end

  defp normalize_memory_filters(_), do: Data.blank_memory_filters()

  defp normalize_graph_filters(params) when is_map(params) do
    defaults = Data.blank_graph_filters()
    timeframe_values = Data.graph_timeframe_values()
    type_values = Data.graph_type_values()

    timeframe =
      params
      |> Map.get("timeframe", defaults["timeframe"])
      |> to_string()
      |> String.trim()
      |> case do
        value ->
          if Enum.member?(timeframe_values, value) do
            value
          else
            defaults["timeframe"]
          end
      end

    type =
      params
      |> Map.get("type", defaults["type"])
      |> to_string()
      |> String.trim()
      |> case do
        value ->
          if Enum.member?(type_values, value) do
            value
          else
            defaults["type"]
          end
      end

    %{
      "query" => params |> Map.get("query", "") |> to_string() |> String.trim(),
      "timeframe" => timeframe,
      "type" => type
    }
  end

  defp normalize_graph_filters(_), do: Data.blank_graph_filters()

  defp merge_graph_data(existing, incoming) do
    nodes =
      unique_by_id((Map.get(existing, :nodes, []) || []) ++ (Map.get(incoming, :nodes, []) || []))

    links =
      unique_by_id((Map.get(existing, :links, []) || []) ++ (Map.get(incoming, :links, []) || []))

    %{nodes: nodes, links: links}
  end

  defp new_links(existing_links, expanded_links) do
    existing_ids =
      existing_links
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(expanded_links, fn link -> MapSet.member?(existing_ids, Map.get(link, :id)) end)
  end

  defp unique_by_id(items) do
    {list, _ids} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, ids} ->
        id = Map.get(item, :id)

        if is_nil(id) or MapSet.member?(ids, id) do
          {acc, ids}
        else
          {[item | acc], MapSet.put(ids, id)}
        end
      end)

    Enum.reverse(list)
  end

  defp api_key_form(form_name) do
    to_form(%{"api_key" => ""}, as: form_name)
  end

  defp persist_model_defaults(socket, params, opts \\ []) when is_map(params) do
    case Context.current_settings_user(socket) do
      nil ->
        put_flash(socket, :error, "You must be logged in.")

      settings_user ->
        base_defaults =
          case ModelDefaults.mode(settings_user) do
            :global -> ModelDefaults.global_defaults()
            :readonly -> %{}
          end

        merged_defaults =
          base_defaults
          |> Map.merge(params)

        case ModelDefaults.save_defaults(settings_user, merged_defaults) do
          :ok ->
            updated_socket =
              socket
              |> reload_current_user_scope()
              |> Loaders.load_models()

            if Keyword.get(opts, :flash?, false) do
              put_flash(updated_socket, :info, "Default models updated")
            else
              updated_socket
            end

          {:error, :not_authorized} ->
            put_flash(socket, :error, "You do not have permission to update model defaults.")

          {:error, reason} ->
            put_flash(socket, :error, "Failed to save defaults: #{inspect(reason)}")
        end
    end
  end

  defp persist_admin_user_model_defaults(socket, user_id, params, opts \\ [])
       when is_map(params) do
    actor = Context.current_settings_user(socket)
    target = Accounts.get_settings_user(user_id)

    cond do
      is_nil(actor) ->
        put_flash(socket, :error, "You must be logged in.")

      is_nil(target) ->
        put_flash(socket, :error, "User not found.")

      true ->
        merged_defaults =
          if Keyword.get(opts, :replace?, false) do
            params
          else
            target
            |> ModelDefaults.user_defaults()
            |> Map.merge(params)
          end

        case ModelDefaults.save_defaults(actor, target, merged_defaults) do
          :ok ->
            updated_socket = Loaders.reload_admin_users(socket)

            case Keyword.get(opts, :flash) do
              message when is_binary(message) -> put_flash(updated_socket, :info, message)
              _ -> updated_socket
            end

          {:error, :not_authorized} ->
            socket
            |> Loaders.reload_admin_users()
            |> put_flash(
              :error,
              "You do not have permission to update this user's model defaults."
            )

          {:error, reason} ->
            put_flash(socket, :error, "Failed to save user defaults: #{inspect(reason)}")
        end
    end
  end

  defp load_model_library(socket) do
    query = socket.assigns[:model_library_query] || ""

    case openrouter_key_for_library(socket) do
      nil ->
        socket
        |> assign(:model_library_all_models, [])
        |> assign(:model_library_models, [])
        |> assign(
          :model_library_error,
          "Connect OpenRouter (or configure OPENROUTER_API_KEY) to browse available models."
        )

      api_key ->
        case OpenRouter.list_models_detailed(api_key) do
          {:ok, models} ->
            socket
            |> assign(:model_library_all_models, models)
            |> assign(:model_library_models, filter_library_models(models, query))
            |> assign(:model_library_error, nil)

          {:error, _reason} ->
            socket
            |> assign(:model_library_all_models, [])
            |> assign(:model_library_models, [])
            |> assign(
              :model_library_error,
              "Could not load OpenRouter models right now. Try again in a moment."
            )
        end
    end
  end

  defp openrouter_key_for_library(socket) do
    case Context.current_settings_user(socket) do
      %{openrouter_api_key: key} when is_binary(key) and key != "" ->
        key

      _ ->
        case IntegrationSettings.get(:openrouter_api_key) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end
    end
  end

  defp filter_library_models(models, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    models
    |> Enum.filter(fn model ->
      normalized == "" ||
        String.contains?(String.downcase(to_string(model.name)), normalized) ||
        String.contains?(String.downcase(to_string(model.id)), normalized)
    end)
    |> Enum.take(300)
  end

  defp apply_model_library_filter(socket) do
    query = socket.assigns[:model_library_query] || ""
    models = socket.assigns[:model_library_all_models] || []
    assign(socket, :model_library_models, filter_library_models(models, query))
  end

  defp maybe_reload_model_library(socket) do
    if socket.assigns[:model_modal_open] do
      load_model_library(socket)
    else
      socket
    end
  end

  defp maybe_save_spending_limit(socket, settings_user_id, params) do
    budget_dollars = params["budget_dollars"] |> to_string() |> String.trim()

    if budget_dollars != "" do
      attrs = %{
        budget_cents: parse_dollars_to_cents(budget_dollars),
        hard_cap: params["hard_cap"] == "true",
        warning_threshold: parse_int(params["warning_threshold"], 80)
      }

      case SpendingLimits.upsert_spending_limit(settings_user_id, attrs) do
        {:ok, _} ->
          socket

        {:error, _} ->
          put_flash(socket, :error, "User created but spending limit failed to save.")
      end
    else
      socket
    end
  end

  defp parse_dollars_to_cents(dollars_str) do
    case Float.parse(to_string(dollars_str)) do
      {amount, _} -> round(amount * 100)
      :error -> 0
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> default
    end
  end
end
