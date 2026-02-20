# test/integration/support/integration_helpers.ex — Helpers for skill integration tests.
#
# Provides context builders, LLM calling utilities, and assertion helpers for
# integration tests. These tests make real LLM API calls to verify that the model
# can correctly invoke skills, and then execute the skill handler with mock
# integrations to verify end-to-end behavior.
#
# Related files:
#   - test/integration/support/mock_integrations.ex (mock integration modules)
#   - lib/assistant/skills/registry.ex (skill lookup)
#   - lib/assistant/skills/executor.ex (skill execution)
#   - lib/assistant/integrations/openrouter.ex (real LLM client)

defmodule Assistant.Integration.Helpers do
  @moduledoc false

  alias Assistant.Integrations.OpenRouter
  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, User}
  alias Assistant.Skills.{Context, Executor, Registry, Result}

  @integration_model "openai/gpt-5-mini"
  @max_llm_timeout 30_000

  # Domains that write to DB tables with user/conversation FK constraints
  @db_domains [:tasks, :memory]

  # -------------------------------------------------------------------
  # Context Builders
  # -------------------------------------------------------------------

  @doc """
  Creates a real user record in the database for integration tests.

  Required for domains (tasks, memory) whose handlers insert rows
  with foreign key constraints referencing the users table.
  """
  def create_test_user! do
    %User{}
    |> User.changeset(%{
      external_id: "integration-test-#{System.unique_integer([:positive])}",
      channel: "test",
      display_name: "Integration Test User"
    })
    |> Repo.insert!()
  end

  @doc """
  Creates a conversation record tied to the given user.

  Required for task update/delete handlers that log history entries
  referencing `changed_via_conversation_id` with a FK constraint.
  """
  def create_test_conversation!(user_id) do
    %Conversation{}
    |> Conversation.changeset(%{
      user_id: user_id,
      channel: "test",
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  @doc """
  Builds a skill context with mock integrations for the given domain.

  For DB-dependent domains (tasks, memory), creates real user and
  conversation records so that foreign key constraints are satisfied.
  Other domains use random UUIDs since they don't write to FK-constrained
  tables.

  Returns a `%Context{}` with the appropriate mock modules injected
  into the integrations map based on the domain.
  """
  def build_context(domain, overrides \\ %{}) do
    {user_id, conversation_id} =
      if domain in @db_domains do
        user = create_test_user!()
        conversation = create_test_conversation!(user.id)
        {user.id, conversation.id}
      else
        {Ecto.UUID.generate(), Ecto.UUID.generate()}
      end

    base = %Context{
      conversation_id: conversation_id,
      execution_id: Ecto.UUID.generate(),
      user_id: user_id,
      channel: :test,
      google_token: google_token_for_domain(domain),
      integrations: integrations_for_domain(domain),
      metadata: metadata_for_domain(domain)
    }

    Map.merge(base, overrides)
  end

  defp integrations_for_domain(:email) do
    %{gmail: Assistant.Integration.MockGmail}
  end

  defp integrations_for_domain(:calendar) do
    %{calendar: Assistant.Integration.MockCalendar}
  end

  defp integrations_for_domain(:files) do
    %{drive: Assistant.Integration.MockDrive}
  end

  defp integrations_for_domain(:images) do
    %{openrouter: Assistant.Integration.MockOpenRouter}
  end

  defp integrations_for_domain(:memory) do
    %{}
  end

  defp integrations_for_domain(:tasks) do
    %{}
  end

  defp integrations_for_domain(:workflow) do
    %{}
  end

  defp integrations_for_domain(_domain) do
    %{
      gmail: Assistant.Integration.MockGmail,
      calendar: Assistant.Integration.MockCalendar,
      drive: Assistant.Integration.MockDrive,
      openrouter: Assistant.Integration.MockOpenRouter
    }
  end

  # Google-dependent domains need a fake token so handlers don't short-circuit
  # with "Google authentication required" before reaching mock integrations.
  @google_domains [:email, :calendar, :files]

  defp google_token_for_domain(domain) when domain in @google_domains do
    "fake-integration-test-token"
  end

  defp google_token_for_domain(_domain), do: nil

  defp metadata_for_domain(domain) when domain in @google_domains do
    %{agent_type: :integration_test, google_token: "fake-integration-test-token"}
  end

  defp metadata_for_domain(_domain) do
    %{agent_type: :integration_test}
  end

  # -------------------------------------------------------------------
  # LLM Tool Calling
  # -------------------------------------------------------------------

  @doc """
  Calls the real LLM with a mission prompt and skill tool definitions.

  The LLM sees the available skills and decides which to call. Returns the
  parsed tool call (skill name + arguments) or text response.

  Returns:
    - `{:tool_call, skill_name, arguments}` if the LLM invokes use_skill
    - `{:text, content}` if the LLM responds with text only
    - `{:error, reason}` on failure
  """
  def ask_llm_for_skill_call(mission, skill_names) do
    system_prompt = build_system_prompt(skill_names)
    tools = build_tools(skill_names)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: mission}
    ]

    opts = [
      model: @integration_model,
      tools: tools,
      temperature: 0.0
    ]

    case OpenRouter.chat_completion(messages, opts) do
      {:ok, response} ->
        parse_llm_response(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_system_prompt(skill_names) do
    skill_descriptions =
      skill_names
      |> Enum.map(fn name ->
        case Registry.lookup(name) do
          {:ok, skill_def} ->
            body_preview = String.slice(skill_def.body, 0, 1500)
            "### #{skill_def.name}\n#{skill_def.description}\n\n#{body_preview}"

          {:error, :not_found} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n---\n\n")

    """
    You are a focused execution agent. Complete the user's request by calling
    the use_skill tool with the appropriate skill and arguments.

    IMPORTANT: You MUST call use_skill to execute the appropriate skill.
    Do NOT respond with text — always use the tool.

    Available skills:
    #{Enum.join(skill_names, ", ")}

    ## Skill Definitions

    #{skill_descriptions}
    """
  end

  defp build_tools(skill_names) do
    skill_defs =
      skill_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        case Registry.lookup(name) do
          {:ok, skill_def} ->
            %{name: skill_def.name, description: skill_def.description}

          {:error, :not_found} ->
            %{name: name, description: "(skill not found)"}
        end
      end)

    skills_desc =
      Enum.map_join(skill_defs, "\n", fn sd ->
        "  - #{sd.name}: #{sd.description}"
      end)

    [
      %{
        type: "function",
        function: %{
          name: "use_skill",
          description: """
          Execute a skill. Available skills:\n#{skills_desc}\n\n\
          Call with the skill name and arguments as a JSON object.\
          """,
          parameters: %{
            "type" => "object",
            "properties" => %{
              "skill" => %{
                "type" => "string",
                "enum" => Enum.map(skill_defs, & &1.name),
                "description" => "The skill to execute"
              },
              "arguments" => %{
                "type" => "object",
                "description" => "Arguments for the skill as key-value pairs"
              }
            },
            "required" => ["skill", "arguments"]
          }
        }
      }
    ]
  end

  defp parse_llm_response(response) do
    cond do
      is_list(response.tool_calls) and response.tool_calls != [] ->
        tc = hd(response.tool_calls)
        name = get_in(tc, [:function, :name]) || get_in(tc, ["function", "name"])
        raw_args = get_in(tc, [:function, :arguments]) || get_in(tc, ["function", "arguments"])

        args =
          case raw_args do
            a when is_binary(a) ->
              case Jason.decode(a) do
                {:ok, decoded} -> decoded
                {:error, _} -> %{}
              end

            a when is_map(a) ->
              a

            _ ->
              %{}
          end

        case name do
          "use_skill" ->
            skill_name = args["skill"]

            # The LLM may nest skill arguments in "arguments" or flatten them
            # alongside "skill". Handle both cases.
            skill_args =
              case args["arguments"] do
                nested when is_map(nested) and map_size(nested) > 0 ->
                  nested

                _ ->
                  # Flatten: all keys except "skill" are the skill's arguments
                  Map.delete(args, "skill")
              end

            {:tool_call, skill_name, skill_args}

          other ->
            {:error, {:unexpected_tool, other}}
        end

      is_binary(response.content) and response.content != "" ->
        {:text, response.content}

      true ->
        {:error, :empty_response}
    end
  end

  # -------------------------------------------------------------------
  # Skill Execution
  # -------------------------------------------------------------------

  @doc """
  Executes a skill handler by name with the given flags and context.

  Looks up the skill in the registry and executes its handler module
  via the Executor (with timeout).
  """
  def execute_skill(skill_name, flags, context) do
    case Registry.lookup(skill_name) do
      {:ok, skill_def} ->
        case skill_def.handler do
          nil ->
            {:ok,
             %Result{
               status: :ok,
               content: "Template skill — no handler to execute."
             }}

          handler_module ->
            Executor.execute(handler_module, flags, context, timeout: @max_llm_timeout)
        end

      {:error, :not_found} ->
        {:error, {:skill_not_found, skill_name}}
    end
  end

  # -------------------------------------------------------------------
  # Full Integration Flow
  # -------------------------------------------------------------------

  @doc """
  Runs the full integration test flow:
  1. Asks real LLM which skill to call for the given mission
  2. Executes the skill handler with mock integrations
  3. Returns the result for assertion

  Accepts either a domain atom (builds fresh context) or a pre-built
  `%Context{}` (useful when setup data must share the same user_id).

  Returns:
    - `{:ok, %{skill: name, flags: args, result: %Result{}}}` on success
    - `{:error, reason}` on failure
  """
  def run_skill_integration(mission, skill_names, domain_or_context)

  def run_skill_integration(mission, skill_names, %Context{} = context) do
    case ask_llm_for_skill_call(mission, skill_names) do
      {:tool_call, skill_name, flags} ->
        case execute_skill(skill_name, flags, context) do
          {:ok, result} ->
            {:ok, %{skill: skill_name, flags: flags, result: result}}

          {:error, reason} ->
            {:error, {:execution_failed, skill_name, reason}}
        end

      {:text, content} ->
        {:error, {:llm_returned_text, content}}

      {:error, reason} ->
        {:error, {:llm_call_failed, reason}}
    end
  end

  def run_skill_integration(mission, skill_names, domain) when is_atom(domain) do
    context = build_context(domain)
    run_skill_integration(mission, skill_names, context)
  end

  # -------------------------------------------------------------------
  # Assertion Helpers
  # -------------------------------------------------------------------

  @doc """
  Asserts that the result is a successful skill execution.
  """
  def assert_skill_success(result) do
    assert_in_delta_or_success(result)
  end

  defp assert_in_delta_or_success(%{result: %Result{status: :ok}}), do: :ok

  defp assert_in_delta_or_success(%{result: %Result{status: :error, content: content}}) do
    raise ExUnit.AssertionError,
      message: "Expected skill success but got error: #{content}"
  end

  @doc """
  Returns true if the mock integration for the given domain was called.
  Uses ETS-backed MockCallRecorder for cross-process visibility.
  """
  def mock_was_called?(domain) do
    ets_domain = normalize_domain(domain)
    Assistant.Integration.MockCallRecorder.called?(ets_domain)
  end

  @doc """
  Returns the list of mock function calls for the given domain.
  """
  def mock_calls(domain) do
    ets_domain = normalize_domain(domain)
    Assistant.Integration.MockCallRecorder.calls(ets_domain)
  end

  @doc """
  Clears recorded mock calls for all domains.
  """
  def clear_mock_calls do
    Assistant.Integration.MockCallRecorder.clear()
  end

  defp normalize_domain(:email), do: :gmail
  defp normalize_domain(:files), do: :drive
  defp normalize_domain(:images), do: :openrouter
  defp normalize_domain(domain), do: domain
end
