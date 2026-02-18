# lib/assistant/skills/workflow/build.ex — workflow.build meta-skill stub.
#
# Creates new workflow files by composing existing skills into
# repeatable markdown definitions. This is a stub implementation
# for Phase 1 — full workflow creation logic will be added later
# when the CLI router and flag validator are implemented.

defmodule Assistant.Skills.Workflow.Build do
  @moduledoc """
  Handler for the `workflow.build` meta-skill.

  Creates new workflow markdown files in the skills directory.
  Workflows are compositions of existing skills for repeatable
  tasks (daily digest, weekly report, etc.).

  This is a Phase 1 stub — the handler validates inputs and
  generates the workflow file. Full integration with the CLI
  router and flag validation will follow in later phases.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.{Registry, Result}

  require Logger

  @skills_dir Application.compile_env(
                :assistant,
                :skills_dir,
                "priv/skills"
              )

  @reserved_names ~w(all help)

  @impl true
  def execute(flags, _context) do
    domain = Map.get(flags, "domain", "workflows")

    with :ok <- validate_required(flags),
         :ok <- validate_name(flags["name"]),
         full_name = "#{domain}.#{flags["name"]}",
         :ok <- validate_no_conflict(full_name) do
      content = generate_workflow_file(full_name, flags)
      path = Path.join([@skills_dir, domain, "#{flags["name"]}.md"])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      Logger.info("Created workflow", name: full_name, path: path)

      {:ok,
       %Result{
         status: :ok,
         content: "Created workflow '#{full_name}' at #{path}. It is now available.",
         side_effects: [:skill_created],
         metadata: %{skill_path: path, skill_name: full_name}
       }}
    end
  end

  # --- Private ---

  defp validate_required(flags) do
    missing =
      ["name", "description"]
      |> Enum.reject(&Map.has_key?(flags, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_flags, missing}}
    end
  end

  defp validate_name(name) do
    cond do
      name in @reserved_names ->
        {:error, "Name '#{name}' is reserved (used by get_skill routing)"}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, "Workflow name must be lowercase alphanumeric + underscore, starting with a letter"}

      true ->
        :ok
    end
  end

  defp validate_no_conflict(name) do
    if Registry.skill_exists?(name) do
      {:error, "Skill '#{name}' already exists. Choose a different name."}
    else
      :ok
    end
  end

  defp generate_workflow_file(full_name, flags) do
    schedule_line =
      if flags["schedule"],
        do: "\nschedule: \"#{flags["schedule"]}\"",
        else: ""

    """
    ---
    name: #{full_name}
    description: #{flags["description"]}#{schedule_line}
    author: assistant
    created: #{Date.utc_today()}
    ---

    # #{full_name}

    #{flags["description"]}

    ## Usage

    #{full_name}

    ## Behavior

    #{Map.get(flags, "steps", "Execute the workflow as described above.")}

    ## Examples

    #{full_name}
    """
  end
end
