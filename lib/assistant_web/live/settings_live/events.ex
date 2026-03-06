defmodule AssistantWeb.SettingsLive.Events do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, push_navigate: 2, redirect: 2]

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUserAllowlistEntry
  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.ConnectedDrives
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Registry
  alias Assistant.Integrations.OpenAI
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive.Changes
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
  alias Assistant.Sync.FileManager
  alias Assistant.Sync.StateStore
  alias Assistant.Sync.Workers.FileSyncWorker
  alias Assistant.Transcripts
  alias Assistant.Workflows
  alias AssistantWeb.SettingsLive.Context
  alias AssistantWeb.SettingsLive.Data
  alias AssistantWeb.SettingsLive.Loaders
  alias AssistantWeb.SettingsLive.Profile
  alias AssistantWeb.SettingsUserAuth

  require Logger

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("switch_admin_tab", %{"tab" => tab}, socket)
      when tab in ~w(integrations models users) do
    {:noreply, assign(socket, :admin_tab, tab)}
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

  def handle_event("refresh_drives", _params, socket) do
    socket = assign(socket, :drives_loading, true)

    user_id = Context.current_user_id(socket)

    token_result =
      if user_id,
        do: GoogleAuth.user_token(user_id),
        else: {:error, :no_user}

    case token_result do
      {:ok, access_token} ->
        case GoogleDrive.list_shared_drives(access_token) do
          {:ok, drives} ->
            {:noreply,
             socket
             |> assign(:available_drives, drives)
             |> assign(:drives_loading, false)
             |> put_flash(:info, "Discovered #{length(drives)} shared drive(s).")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:drives_loading, false)
             |> put_flash(:error, "Failed to fetch shared drives from Google.")}
        end

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:drives_loading, false)
         |> put_flash(:error, "Connect your Google account first to discover drives.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:drives_loading, false)
         |> put_flash(:error, "Google credentials not configured.")}
    end
  end

  def handle_event("toggle_drive", %{"id" => id, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case ensure_drive_for_access(socket, %{"id" => id}, enabled?) do
      {:ok, drive, socket} ->
        {:noreply,
         socket
         |> maybe_ensure_drive_cursor(drive, enabled?)
         |> reload_google_workspace_access()
         |> refresh_manager_drive()
         |> reconcile_drive_workspace(drive.drive_id)}

      {:error, :not_found, socket} ->
        {:noreply, put_flash(socket, :error, "Drive not found.")}

      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, _reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle drive.")}
    end
  end

  def handle_event("toggle_drive", params, socket) do
    enabled? = Map.get(params, "enabled") == "true"

    case ensure_drive_for_access(socket, params, enabled?) do
      {:ok, drive, socket} ->
        {:noreply,
         socket
         |> maybe_ensure_drive_cursor(drive, enabled?)
         |> reload_google_workspace_access()
         |> refresh_manager_drive()
         |> reconcile_drive_workspace(drive.drive_id)}

      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, _reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle drive.")}
    end
  end

  def handle_event("connect_drive", %{"drive_id" => drive_id, "name" => name}, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
      attrs = %{drive_id: drive_id, drive_name: name, drive_type: "shared"}

      case ConnectedDrives.connect(user_id, attrs) do
        {:ok, drive} ->
          {:noreply,
           socket
           |> maybe_ensure_drive_cursor(drive, true)
           |> reload_google_workspace_access()
           |> refresh_manager_drive()
           |> reconcile_drive_workspace(drive.drive_id)
           |> put_flash(:info, "Connected #{name}.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to connect #{name}.")}
      end
    end)
  end

  def handle_event("connect_personal_drive", _params, socket) do
    Context.with_linked_user(socket, fn _settings_user, user_id ->
      case ConnectedDrives.ensure_personal_drive(user_id) do
        {:ok, drive} ->
          {:noreply,
           socket
           |> maybe_ensure_drive_cursor(drive, true)
           |> reload_google_workspace_access()
           |> refresh_manager_drive()
           |> reconcile_drive_workspace(drive.drive_id)
           |> put_flash(:info, "Connected My Drive.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to connect My Drive.")}
      end
    end)
  end

  def handle_event("disconnect_drive", %{"id" => id}, socket) do
    case ConnectedDrives.disconnect(id) do
      {:ok, _drive} ->
        {:noreply,
         socket
         |> Loaders.load_connected_drives()
         |> refresh_manager_drive()
         |> put_flash(:info, "Drive disconnected.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to disconnect drive.")}
    end
  end

  def handle_event("open_drive_scope_manager", params, socket) do
    with {:ok, drive, socket} <- ensure_drive_for_access(socket, params, :preserve),
         socket <- assign(socket, :drive_tree_error, nil),
         {:ok, socket} <- load_drive_tree_root(socket, drive) do
      {:noreply,
       socket
       |> assign(:drive_manager_drive, drive_to_manager_assign(drive))
       |> refresh_manager_drive()}
    else
      {:error, :not_connected, socket} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, reason, socket} ->
        {:noreply,
         socket
         |> assign(:drive_tree_error, drive_tree_error_message(reason))
         |> put_flash(:error, "Failed to load drive contents.")}
    end
  end

  def handle_event("close_drive_scope_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:drive_manager_drive, nil)
     |> assign(:drive_tree_nodes, %{})
     |> assign(:drive_tree_root_keys, [])
     |> assign(:drive_tree_expanded, MapSet.new())
     |> assign(:drive_tree_loading, false)
     |> assign(:drive_tree_loading_nodes, MapSet.new())
     |> assign(:drive_tree_error, nil)}
  end

  def handle_event("toggle_drive_tree_node_expanded", %{"node_key" => node_key}, socket) do
    node = socket.assigns.drive_tree_nodes[node_key]
    expanded = socket.assigns.drive_tree_expanded || MapSet.new()

    cond do
      is_nil(node) or node.node_type != "folder" ->
        {:noreply, socket}

      MapSet.member?(expanded, node_key) ->
        {:noreply, assign(socket, :drive_tree_expanded, MapSet.delete(expanded, node_key))}

      node.children_loaded? ->
        {:noreply, assign(socket, :drive_tree_expanded, MapSet.put(expanded, node_key))}

      true ->
        socket =
          assign(
            socket,
            :drive_tree_loading_nodes,
            MapSet.put(socket.assigns.drive_tree_loading_nodes, node_key)
          )

        case load_drive_tree_children(socket, node) do
          {:ok, socket} ->
            {:noreply,
             socket
             |> assign(
               :drive_tree_loading_nodes,
               MapSet.delete(socket.assigns.drive_tree_loading_nodes, node_key)
             )
             |> assign(
               :drive_tree_expanded,
               MapSet.put(socket.assigns.drive_tree_expanded, node_key)
             )
             |> assign(:drive_tree_error, nil)}

          {:error, reason, socket} ->
            {:noreply,
             socket
             |> assign(
               :drive_tree_loading_nodes,
               MapSet.delete(socket.assigns.drive_tree_loading_nodes, node_key)
             )
             |> assign(:drive_tree_error, drive_tree_error_message(reason))
             |> put_flash(:error, "Failed to load folder contents.")}
        end
    end
  end

  def handle_event("toggle_drive_tree_node_scope", %{"node_key" => node_key}, socket) do
    with %{drive_id: drive_id} = manager_drive when not is_nil(manager_drive) <-
           socket.assigns[:drive_manager_drive],
         user_id when is_binary(user_id) <- Context.current_user_id(socket),
         node when not is_nil(node) <- socket.assigns.drive_tree_nodes[node_key],
         {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, socket} <- persist_tree_scope_toggle(socket, user_id, access_token, drive_id, node) do
      {:noreply,
       socket
       |> Loaders.load_sync_scopes()
       |> refresh_manager_drive()
       |> reconcile_drive_workspace(drive_id)}
    else
      nil ->
        {:noreply, socket}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Connect your Google account first.")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, drive_tree_error_message(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to update Drive access.")}
    end
  end

  def handle_event("open_sync_target_browser", _params, socket) do
    drives = sync_target_drives(socket)

    if drives == [] do
      {:noreply, put_flash(socket, :error, "Connect and enable at least one drive first.")}
    else
      selected_drive =
        socket.assigns[:sync_target_selected_drive] ||
          drives |> List.first() |> Map.get(:value)

      {:noreply,
       socket
       |> assign(:sync_target_browser_open, true)
       |> assign(:sync_target_drives, drives)
       |> assign(:sync_target_selected_drive, selected_drive)
       |> assign(:sync_target_error, nil)
       |> load_sync_target_folders(selected_drive)}
    end
  end

  def handle_event("close_sync_target_browser", _params, socket) do
    {:noreply,
     socket
     |> assign(:sync_target_browser_open, false)
     |> assign(:sync_target_loading, false)
     |> assign(:sync_target_error, nil)}
  end

  def handle_event("change_sync_target_drive", %{"sync_target_browser" => params}, socket) do
    selected_drive = Map.get(params, "drive_id", "")

    {:noreply,
     socket
     |> assign(:sync_target_selected_drive, selected_drive)
     |> assign(:sync_target_error, nil)
     |> load_sync_target_folders(selected_drive)}
  end

  def handle_event(
        "add_sync_target",
        %{"drive_id" => raw_drive_id, "folder_id" => folder_id, "folder_name" => folder_name},
        socket
      ) do
    drive_id = normalize_sync_drive_id(raw_drive_id)
    folder_name = String.trim(to_string(folder_name))

    if folder_name == "" do
      {:noreply, put_flash(socket, :error, "Folder name is required.")}
    else
      Context.with_linked_user(socket, fn _settings_user, user_id ->
        with {:ok, access_token} <- GoogleAuth.user_token(user_id),
             {:ok, _scope} <-
               StateStore.upsert_scope(%{
                 user_id: user_id,
                 drive_id: drive_id,
                 folder_id: folder_id,
                 folder_name: folder_name,
                 access_level: "read_write"
               }),
             {:ok, token} <-
               drive_changes_module().get_start_page_token(access_token, drive_id: drive_id),
             {:ok, _cursor} <-
               StateStore.upsert_cursor(%{
                 user_id: user_id,
                 drive_id: drive_id,
                 start_page_token: token
               }) do
          {:noreply,
           socket
           |> assign(:sync_target_browser_open, false)
           |> assign(:sync_target_loading, false)
           |> assign(:sync_target_error, nil)
           |> Loaders.load_sync_scopes()
           |> reconcile_drive_workspace(drive_id)
           |> put_flash(:info, "Added sync target #{folder_name}.")}
        else
          {:error, :not_connected} ->
            {:noreply,
             socket
             |> assign(:sync_target_loading, false)
             |> put_flash(:error, "Connect your Google account first.")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:sync_target_loading, false)
             |> put_flash(:error, "Failed to add sync target.")}
        end
      end)
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

    Context.with_settings_user(socket, fn settings_user ->
      case Context.ensure_linked_user(settings_user) do
        {:ok, user_id} ->
          case SkillPermissions.set_enabled_for_user(user_id, skill, enabled?) do
            {:ok, _override} ->
              {:noreply,
               socket
               |> reload_current_user_scope()
               |> Loaders.load_personal_skill_permissions()
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

  def handle_event("save_profile", %{"profile" => params}, socket) do
    Profile.save_profile(socket, params, flash?: true)
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

  defp reload_google_workspace_access(socket) do
    socket
    |> Loaders.load_connected_drives()
    |> Loaders.load_sync_scopes()
  end

  defp refresh_manager_drive(socket) do
    case socket.assigns[:drive_manager_drive] do
      nil ->
        socket

      manager_drive ->
        refreshed =
          Enum.find(socket.assigns[:connected_drives] || [], fn drive ->
            drive.drive_type == manager_drive.drive_type and
              drive.drive_id == manager_drive.drive_id
          end)

        case refreshed do
          nil ->
            assign(socket, :drive_manager_drive, %{
              manager_drive
              | connected_id: nil,
                enabled: false
            })

          drive ->
            assign(socket, :drive_manager_drive, drive_to_manager_assign(drive))
        end
    end
  end

  defp drive_to_manager_assign(drive) do
    %{
      drive_key: drive_access_key(drive.drive_type, drive.drive_id),
      drive_id: drive.drive_id,
      drive_name: drive.drive_name,
      drive_type: drive.drive_type,
      connected_id: drive.id,
      enabled: drive.enabled
    }
  end

  defp ensure_drive_for_access(socket, %{"id" => id} = params, mode)
       when is_binary(id) and id != "" do
    case ConnectedDrives.get(id) do
      nil ->
        ensure_drive_for_access(socket, Map.delete(params, "id"), mode)

      drive ->
        case mode do
          :preserve ->
            {:ok, drive, socket}

          enabled? when is_boolean(enabled?) and drive.enabled != enabled? ->
            case ConnectedDrives.toggle(id, enabled?) do
              {:ok, updated_drive} -> {:ok, updated_drive, socket}
              {:error, reason} -> {:error, reason, socket}
            end

          _ ->
            {:ok, drive, socket}
        end
    end
  end

  defp ensure_drive_for_access(socket, params, mode) do
    case Context.current_settings_user(socket) do
      nil ->
        {:error, :not_connected, socket}

      settings_user ->
        with {:ok, user_id} <- Context.ensure_linked_user(settings_user),
             attrs <- drive_attrs_from_params(params, mode),
             {:ok, drive} <- ConnectedDrives.connect(user_id, attrs) do
          {:ok, drive, reload_current_user_scope(socket)}
        else
          {:error, reason} -> {:error, reason, socket}
        end
    end
  end

  defp drive_attrs_from_params(params, mode) do
    drive_id =
      params
      |> Map.get("drive_id")
      |> normalize_sync_drive_id()

    drive_type =
      case Map.get(params, "drive_type") do
        "shared" -> "shared"
        _ when is_nil(drive_id) -> "personal"
        _ -> "shared"
      end

    enabled? =
      case mode do
        :preserve -> false
        value when is_boolean(value) -> value
      end

    %{
      drive_id: drive_id,
      drive_name:
        Map.get(
          params,
          "drive_name",
          if(drive_type == "personal", do: "My Drive", else: "Shared Drive")
        ),
      drive_type: drive_type,
      enabled: enabled?
    }
  end

  defp load_drive_tree_root(socket, drive) do
    socket =
      socket
      |> assign(:drive_tree_loading, true)
      |> assign(:drive_tree_error, nil)
      |> assign(:drive_tree_nodes, %{})
      |> assign(:drive_tree_root_keys, [])
      |> assign(:drive_tree_expanded, MapSet.new())
      |> assign(:drive_tree_loading_nodes, MapSet.new())

    with user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, children} <- list_drive_children(access_token, drive.drive_id, :root) do
      {nodes, root_keys} = merge_drive_tree_children(%{}, nil, children)

      {:ok,
       socket
       |> assign(:drive_tree_nodes, nodes)
       |> assign(:drive_tree_root_keys, root_keys)
       |> assign(:drive_tree_loading, false)}
    else
      {:error, reason} ->
        {:error, reason, assign(socket, :drive_tree_loading, false)}

      _ ->
        {:error, :not_connected, assign(socket, :drive_tree_loading, false)}
    end
  end

  defp load_drive_tree_children(socket, node) do
    with %{drive_id: drive_id} <- socket.assigns[:drive_manager_drive],
         user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, children} <- list_drive_children(access_token, drive_id, node.id) do
      {nodes, _child_keys} =
        merge_drive_tree_children(socket.assigns.drive_tree_nodes, node.key, children)

      {:ok, assign(socket, :drive_tree_nodes, nodes)}
    else
      {:error, reason} -> {:error, reason, socket}
      _ -> {:error, :not_connected, socket}
    end
  end

  defp list_drive_children(access_token, drive_id, parent_id) do
    query = drive_children_query(drive_id, parent_id)

    case drive_module().list_files(access_token, query, drive_children_query_opts(drive_id)) do
      {:ok, files} -> {:ok, sort_drive_items(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_drive_tree_children(nodes, parent_key, children) do
    Enum.reduce(children, {nodes, []}, fn child, {acc_nodes, child_keys} ->
      node_key = drive_tree_node_key(child)
      existing = Map.get(acc_nodes, node_key, %{})
      folder? = drive_folder?(child.mime_type)

      node =
        existing
        |> Map.merge(%{
          key: node_key,
          id: child.id,
          name: child.name,
          mime_type: child.mime_type,
          node_type: if(folder?, do: "folder", else: "file"),
          file_kind: drive_file_kind(child.mime_type),
          parent_key: parent_key
        })
        |> Map.put_new(:child_keys, [])
        |> Map.put(
          :children_loaded?,
          if(folder?, do: Map.get(existing, :children_loaded?, false), else: true)
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

      {nodes_with_parent, child_keys}
    end)
  end

  defp persist_tree_scope_toggle(socket, user_id, access_token, drive_id, node) do
    {inherited_selected?, currently_selected?} = tree_node_selection(socket, node)
    desired_selected? = !currently_selected?
    explicit_scope = explicit_scope_for_node(user_id, drive_id, node)

    with :ok <- maybe_clear_descendant_scopes(user_id, access_token, drive_id, node),
         :ok <-
           persist_explicit_scope(
             user_id,
             drive_id,
             socket.assigns.drive_tree_nodes,
             node,
             explicit_scope,
             inherited_selected?,
             desired_selected?
           ) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp maybe_clear_descendant_scopes(_user_id, _access_token, _drive_id, %{node_type: "file"}),
    do: :ok

  defp maybe_clear_descendant_scopes(user_id, access_token, drive_id, %{
         node_type: "folder",
         id: folder_id
       }) do
    with {:ok, descendants} <- fetch_subtree_descendants(access_token, drive_id, folder_id) do
      _ =
        StateStore.delete_scopes_in_targets(
          user_id,
          drive_id,
          descendants.folder_ids,
          descendants.file_ids
        )

      :ok
    end
  end

  defp persist_explicit_scope(
         user_id,
         drive_id,
         tree_nodes,
         node,
         existing_scope,
         inherited_selected?,
         desired_selected?
       ) do
    if desired_selected? == inherited_selected? do
      case existing_scope do
        nil ->
          :ok

        scope ->
          case StateStore.delete_scope(scope) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    else
      attrs =
        %{
          user_id: user_id,
          drive_id: drive_id,
          access_level: "read_write",
          scope_effect: if(desired_selected?, do: "include", else: "exclude")
        }
        |> Map.merge(node_scope_attrs(node, tree_nodes))

      case StateStore.upsert_scope(attrs) do
        {:ok, _scope} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp node_scope_attrs(%{node_type: "folder", id: folder_id, name: folder_name}, _nodes) do
    %{folder_id: folder_id}
    |> Map.put(:folder_name, folder_name)
  end

  defp node_scope_attrs(
         %{node_type: "file", id: file_id, name: file_name, mime_type: mime_type} = node,
         nodes
       ) do
    %{
      folder_id: parent_folder_id(node),
      folder_name: node_folder_name(node, nodes),
      file_id: file_id,
      file_name: file_name,
      file_mime_type: mime_type
    }
  end

  defp parent_folder_id(%{parent_key: nil}), do: nil

  defp parent_folder_id(%{parent_key: parent_key} = _node) do
    case parent_key do
      "folder:" <> folder_id -> folder_id
      _ -> nil
    end
  end

  defp node_folder_name(%{parent_key: nil, name: name}, _nodes), do: name

  defp node_folder_name(%{parent_key: parent_key, name: name}, nodes) do
    case Map.get(nodes, parent_key) do
      %{name: parent_name} -> parent_name
      _ -> name
    end
  end

  defp explicit_scope_for_node(user_id, drive_id, %{node_type: "folder", id: folder_id}) do
    StateStore.get_scope(user_id, drive_id, folder_id)
  end

  defp explicit_scope_for_node(user_id, drive_id, %{node_type: "file", id: file_id}) do
    StateStore.get_file_scope(user_id, drive_id, file_id)
  end

  defp tree_node_selection(socket, node) do
    drive_id = socket.assigns.drive_manager_drive && socket.assigns.drive_manager_drive.drive_id

    inherited_selected? =
      node_ancestor_chain(socket.assigns.drive_tree_nodes, node)
      |> Enum.reduce(false, fn ancestor, acc ->
        case explicit_effect_for_tree_node(socket.assigns.sync_scopes, drive_id, ancestor) do
          "include" -> true
          "exclude" -> false
          nil -> acc
        end
      end)

    current_selected? =
      case explicit_effect_for_tree_node(socket.assigns.sync_scopes, drive_id, node) do
        "include" -> true
        "exclude" -> false
        nil -> inherited_selected?
      end

    {inherited_selected?, current_selected?}
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

  defp explicit_effect_for_tree_node(sync_scopes, drive_id, %{node_type: "folder", id: folder_id}) do
    case Enum.find(
           sync_scopes,
           &(&1.drive_id == drive_id and &1.scope_type == "folder" and &1.folder_id == folder_id)
         ) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_effect_for_tree_node(sync_scopes, drive_id, %{node_type: "file", id: file_id}) do
    case Enum.find(
           sync_scopes,
           &(&1.drive_id == drive_id and &1.scope_type == "file" and &1.file_id == file_id)
         ) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp fetch_subtree_descendants(access_token, drive_id, folder_id) do
    do_fetch_subtree_descendants(access_token, drive_id, [folder_id], MapSet.new(), MapSet.new())
  end

  defp do_fetch_subtree_descendants(_access_token, _drive_id, [], folder_ids, file_ids) do
    {:ok, %{folder_ids: MapSet.to_list(folder_ids), file_ids: MapSet.to_list(file_ids)}}
  end

  defp do_fetch_subtree_descendants(
         access_token,
         drive_id,
         [folder_id | rest],
         folder_ids,
         file_ids
       ) do
    with {:ok, children} <- list_drive_children(access_token, drive_id, folder_id) do
      {child_folders, child_files} = Enum.split_with(children, &drive_folder?(&1.mime_type))

      next_queue = rest ++ Enum.map(child_folders, & &1.id)
      next_folder_ids = Enum.reduce(child_folders, folder_ids, &MapSet.put(&2, &1.id))
      next_file_ids = Enum.reduce(child_files, file_ids, &MapSet.put(&2, &1.id))

      do_fetch_subtree_descendants(
        access_token,
        drive_id,
        next_queue,
        next_folder_ids,
        next_file_ids
      )
    end
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

  defp drive_tree_node_key(%{mime_type: mime_type, id: id}) do
    if drive_folder?(mime_type), do: "folder:#{id}", else: "file:#{id}"
  end

  defp drive_access_key("personal", _drive_id), do: "personal"
  defp drive_access_key(_drive_type, drive_id), do: "drive:#{drive_id}"

  defp drive_folder?("application/vnd.google-apps.folder"), do: true
  defp drive_folder?(_), do: false

  defp drive_file_kind("application/vnd.google-apps.document"), do: "doc"
  defp drive_file_kind("application/vnd.google-apps.spreadsheet"), do: "sheet"
  defp drive_file_kind("application/vnd.google-apps.presentation"), do: "slides"
  defp drive_file_kind("application/pdf"), do: "pdf"

  defp drive_file_kind(mime_type) when is_binary(mime_type) do
    if String.starts_with?(mime_type, "image/"), do: "image", else: "file"
  end

  defp drive_file_kind(_), do: "file"

  defp drive_tree_error_message(:not_connected), do: "Connect your Google account first."
  defp drive_tree_error_message(:not_found), do: "Drive item not found."
  defp drive_tree_error_message(_), do: "Unable to update Drive access."

  defp drive_module do
    Application.get_env(:assistant, :google_drive_module, GoogleDrive)
  end

  defp file_sync_worker_module do
    Application.get_env(:assistant, :google_drive_file_sync_worker_module, FileSyncWorker)
  end

  defp reconcile_drive_workspace(socket, drive_id) do
    with user_id when is_binary(user_id) <- Context.current_user_id(socket),
         {:ok, access_token} <- GoogleAuth.user_token(user_id) do
      prune_revoked_drive_files(user_id, access_token, drive_id)
      backfill_accessible_drive_files(user_id, access_token, drive_id)
      socket
    else
      _ -> socket
    end
  end

  defp prune_revoked_drive_files(user_id, access_token, drive_id) do
    user_id
    |> synced_files_for_drive(drive_id)
    |> Enum.each(fn synced_file ->
      case drive_module().get_file(access_token, synced_file.drive_file_id) do
        {:ok, remote_file} ->
          unless drive_file_accessible?(user_id, drive_id, remote_file) do
            _ = FileManager.delete_file(user_id, synced_file.local_path)
            _ = StateStore.delete_synced_file(synced_file)
          end

        {:error, :not_found} ->
          _ = FileManager.delete_file(user_id, synced_file.local_path)
          _ = StateStore.delete_synced_file(synced_file)

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp backfill_accessible_drive_files(user_id, access_token, drive_id) do
    existing_ids =
      user_id
      |> synced_files_for_drive(drive_id)
      |> MapSet.new(& &1.drive_file_id)

    access_token
    |> list_all_drive_files(drive_id)
    |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
    |> Enum.filter(&drive_file_accessible?(user_id, drive_id, &1))
    |> Enum.each(fn remote_file ->
      args = %{
        action: "upsert",
        user_id: user_id,
        drive_id: drive_id,
        drive_file_id: remote_file.id,
        access_token: access_token,
        change: %{
          file_id: remote_file.id,
          name: remote_file.name,
          mime_type: remote_file.mime_type,
          modified_time: Map.get(remote_file, :modified_time),
          size: Map.get(remote_file, :size),
          parents: remote_file.parents || []
        }
      }

      _ = args |> file_sync_worker_module().new() |> Oban.insert()
    end)
  end

  defp synced_files_for_drive(user_id, nil),
    do: StateStore.list_synced_files(user_id, drive_id: :personal)

  defp synced_files_for_drive(user_id, drive_id),
    do: StateStore.list_synced_files(user_id, drive_id: drive_id)

  defp drive_file_accessible?(user_id, drive_id, remote_file) do
    ConnectedDrives.enabled?(user_id, drive_id) or
      StateStore.file_in_scope?(
        user_id,
        drive_id,
        first_parent_from_metadata(remote_file),
        remote_file.id
      ) != nil
  end

  defp first_parent_from_metadata(%{parents: [parent | _]}), do: parent
  defp first_parent_from_metadata(%{"parents" => [parent | _]}), do: parent
  defp first_parent_from_metadata(_), do: nil

  defp list_all_drive_files(access_token, drive_id) do
    do_list_all_drive_files(access_token, drive_id, [:root], [], MapSet.new())
  end

  defp do_list_all_drive_files(_access_token, _drive_id, [], files, _seen_folders), do: files

  defp do_list_all_drive_files(access_token, drive_id, [parent_id | rest], files, seen_folders) do
    folder_key = {drive_id, parent_id}

    if MapSet.member?(seen_folders, folder_key) do
      do_list_all_drive_files(access_token, drive_id, rest, files, seen_folders)
    else
      children =
        case list_drive_children(access_token, drive_id, parent_id) do
          {:ok, items} -> items
          {:error, _reason} -> []
        end

      {folders, regular_files} = Enum.split_with(children, &drive_folder?(&1.mime_type))

      do_list_all_drive_files(
        access_token,
        drive_id,
        rest ++ Enum.map(folders, & &1.id),
        files ++ regular_files,
        MapSet.put(seen_folders, folder_key)
      )
    end
  end

  defp sync_target_drives(socket) do
    socket.assigns[:connected_drives]
    |> List.wrap()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn drive ->
      value = if drive.drive_type == "personal", do: "__personal__", else: drive.drive_id

      %{
        value: value,
        label: drive.drive_name
      }
    end)
  end

  defp load_sync_target_folders(socket, raw_drive_id) do
    drive_id = normalize_sync_drive_id(raw_drive_id)

    query = "mimeType='application/vnd.google-apps.folder' and trashed=false"
    folder_opts = sync_folder_query_opts(drive_id)

    socket =
      socket
      |> assign(:sync_target_loading, true)
      |> assign(:sync_target_folders, [])

    case Context.current_user_id(socket) do
      nil ->
        socket
        |> assign(:sync_target_loading, false)
        |> assign(:sync_target_error, "No linked user account.")

      user_id ->
        case GoogleAuth.user_token(user_id) do
          {:ok, access_token} ->
            case GoogleDrive.list_files(access_token, query, folder_opts) do
              {:ok, folders} ->
                normalized_folders =
                  folders
                  |> Enum.map(fn folder -> %{id: folder.id, name: folder.name} end)
                  |> Enum.sort_by(&String.downcase(&1.name || ""))

                socket
                |> assign(:sync_target_loading, false)
                |> assign(:sync_target_error, nil)
                |> assign(:sync_target_folders, normalized_folders)

              {:error, _reason} ->
                socket
                |> assign(:sync_target_loading, false)
                |> assign(:sync_target_error, "Unable to load folders for this drive.")
            end

          {:error, :not_connected} ->
            socket
            |> assign(:sync_target_loading, false)
            |> assign(:sync_target_error, "Connect your Google account first.")

          {:error, _reason} ->
            socket
            |> assign(:sync_target_loading, false)
            |> assign(:sync_target_error, "Google authorization is unavailable.")
        end
    end
  end

  defp normalize_sync_drive_id(""), do: nil
  defp normalize_sync_drive_id("__personal__"), do: nil
  defp normalize_sync_drive_id(nil), do: nil
  defp normalize_sync_drive_id(drive_id), do: drive_id

  defp drive_changes_module do
    Application.get_env(:assistant, :google_drive_changes_module, Changes)
  end

  defp maybe_ensure_drive_cursor(socket, _drive, false), do: socket

  defp maybe_ensure_drive_cursor(socket, drive, true) do
    with %{user_id: user_id} when is_binary(user_id) <- drive,
         {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, token} <-
           drive_changes_module().get_start_page_token(access_token, drive_id: drive.drive_id) do
      _ =
        StateStore.upsert_cursor(%{
          user_id: user_id,
          drive_id: drive.drive_id,
          start_page_token: token
        })

      socket
    else
      _ -> socket
    end
  end

  defp sync_folder_query_opts(nil) do
    [
      pageSize: 100,
      orderBy: "name",
      corpora: "user",
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
  end

  defp sync_folder_query_opts(drive_id) do
    [
      pageSize: 100,
      orderBy: "name",
      corpora: "drive",
      driveId: drive_id,
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
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
end
