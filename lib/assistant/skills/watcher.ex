# lib/assistant/skills/watcher.ex — FileSystem watcher for skill hot-reload.
#
# Watches the skills directory for .md file changes and notifies the
# Registry to reload or remove skills at runtime. This enables skill
# creation and modification without recompiling or restarting the app.

defmodule Assistant.Skills.Watcher do
  @moduledoc """
  Watches the skills directory for file changes and triggers
  hot-reload in the Registry.

  Uses the `file_system` library to monitor create, modify, and
  delete events on `.md` files. On change, delegates to the Registry
  GenServer for safe ETS table updates.

  Started as part of the supervision tree after the Registry.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    skills_dir = Keyword.get(opts, :skills_dir, default_skills_dir())

    case FileSystem.start_link(dirs: [skills_dir]) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)

        Logger.info("Skill file watcher started", dir: skills_dir)

        {:ok, %{watcher_pid: watcher_pid, skills_dir: skills_dir}}

      {:error, reason} ->
        Logger.warning("Failed to start skill file watcher, hot-reload disabled",
          dir: skills_dir,
          reason: inspect(reason)
        )

        {:ok, %{watcher_pid: nil, skills_dir: skills_dir}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    if String.ends_with?(path, ".md") do
      handle_md_event(path, events)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("Skill file watcher stopped unexpectedly")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp handle_md_event(path, events) do
    cond do
      :removed in events or :deleted in events ->
        Logger.debug("Skill file removed", path: path)
        Assistant.Skills.Registry.remove_skill(path)

      :created in events or :modified in events or :renamed in events ->
        Logger.debug("Skill file changed", path: path, events: inspect(events))
        Assistant.Skills.Registry.reload_skill(path)

      true ->
        :ok
    end
  end

  defp default_skills_dir do
    Application.get_env(:assistant, :skills_dir, Path.join(:code.priv_dir(:assistant), "skills"))
  end
end
