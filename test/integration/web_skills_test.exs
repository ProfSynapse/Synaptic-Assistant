# test/integration/web_skills_test.exs
#
# Real-provider integration coverage for the new web search and fetch skills.
# These tests exercise:
#   - OpenRouter native web search with real citations
#   - the web.search skill wrapper
#   - deterministic web.fetch + save_to against a public page
#
# Run explicitly with exported secrets, for example:
#   set -a; source .env; set +a
#   mix test --include integration test/integration/web_skills_test.exs

defmodule Assistant.Integration.WebSkillsTest do
  use ExUnit.Case, async: false

  import Assistant.Integration.TestLogger

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Assistant.Integrations.OpenRouter
  alias Assistant.Skills.Context
  alias Assistant.Skills.Result
  alias Assistant.Skills.Web.{Fetch, Search}
  alias Assistant.Sync.FileManager

  @integration_model "openai/gpt-5.2"
  @real_fetch_url "https://elixir-lang.org/"

  setup do
    api_key = System.get_env("OPENROUTER_API_KEY")
    original_openrouter_key = Application.get_env(:assistant, :openrouter_api_key)
    original_workspace_dir = Application.get_env(:assistant, :sync_workspace_dir)

    if is_binary(api_key) and api_key != "" do
      Application.put_env(:assistant, :openrouter_api_key, api_key)
    end

    tmp_dir =
      Path.join(System.tmp_dir!(), "web_skills_integration_#{System.unique_integer([:positive])}")

    Application.put_env(:assistant, :sync_workspace_dir, tmp_dir)

    on_exit(fn ->
      if original_openrouter_key do
        Application.put_env(:assistant, :openrouter_api_key, original_openrouter_key)
      else
        Application.delete_env(:assistant, :openrouter_api_key)
      end

      if original_workspace_dir do
        Application.put_env(:assistant, :sync_workspace_dir, original_workspace_dir)
      else
        Application.delete_env(:assistant, :sync_workspace_dir)
      end
    end)

    {:ok, api_key: api_key, tmp_dir: tmp_dir}
  end

  describe "real OpenRouter web search" do
    @tag :integration
    test "returns cited answer text from the native web plugin", context do
      require_api_key!(context)

      query = "What is the Elixir programming language? Answer briefly with citations."

      log_request("openrouter.web_search", %{
        model: @integration_model,
        query: query,
        max_results: 3
      })

      {elapsed, result} =
        timed(fn ->
          OpenRouter.web_search(query,
            api_key: context.api_key,
            model: @integration_model,
            engine: "native",
            max_results: 3,
            search_context_size: "medium"
          )
        end)

      assert {:ok, response} = result
      log_response("openrouter.web_search", {:ok, response})
      log_pass("openrouter.web_search", elapsed)

      assert is_binary(response.content)
      assert String.length(String.trim(response.content)) > 20
      assert is_list(response.citations)
      assert length(response.citations) >= 1

      assert Enum.all?(response.citations, fn citation ->
               is_binary(citation.url) and String.starts_with?(citation.url, "http")
             end)

      combined_text =
        response.content <>
          Enum.map_join(response.citations, "\n", fn citation ->
            [citation.title, citation.url]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")
          end)

      assert combined_text =~ ~r/elixir/i
    end

    @tag :integration
    test "web.search skill formats the cited answer", context do
      require_api_key!(context)

      skill_context = %Context{
        conversation_id: Ecto.UUID.generate(),
        execution_id: Ecto.UUID.generate(),
        user_id: "integration-web-search",
        channel: :test,
        integrations: %{openrouter: OpenRouter}
      }

      query = "What is Phoenix Framework in Elixir? Answer briefly with citations."

      log_request("skill.web.search", %{
        model: @integration_model,
        query: query,
        provider: "openrouter"
      })

      {elapsed, result} =
        timed(fn ->
          Search.execute(
            %{
              "query" => query,
              "provider" => "openrouter",
              "model" => @integration_model,
              "limit" => "3",
              "engine" => "native"
            },
            skill_context
          )
        end)

      assert {:ok, %Result{status: :ok, content: content, metadata: metadata}} = result
      log_response("skill.web.search", {:ok, %{content: content, metadata: metadata}})
      log_pass("skill.web.search", elapsed)

      assert content =~ "Citations:"
      assert metadata.provider == "openrouter"
      assert is_binary(metadata.model)
      assert is_list(metadata.citations)
      assert length(metadata.citations) >= 1
    end
  end

  describe "real web fetch" do
    @tag :integration
    test "web.fetch reads and saves a public page", _context do
      user_id = Ecto.UUID.generate()

      skill_context = %Context{
        conversation_id: Ecto.UUID.generate(),
        execution_id: Ecto.UUID.generate(),
        user_id: user_id,
        channel: :test,
        integrations: %{}
      }

      log_request("skill.web.fetch", %{
        url: @real_fetch_url,
        save_to: "research/elixir-homepage.md"
      })

      {elapsed, result} =
        timed(fn ->
          Fetch.execute(
            %{
              "url" => @real_fetch_url,
              "save_to" => "research/elixir-homepage.md",
              "max_chars" => "1500"
            },
            skill_context
          )
        end)

      assert {:ok,
              %Result{status: :ok, content: content, files_produced: files, metadata: metadata}} =
               result

      log_response("skill.web.fetch", {:ok, %{content: content, metadata: metadata}})
      log_pass("skill.web.fetch", elapsed)

      assert content =~ "Source:"
      assert content =~ "Fetched At:"
      assert is_binary(metadata.final_url)
      assert is_binary(metadata.content_type)
      assert String.starts_with?(metadata.content_type, "text/html")
      assert [%{path: "research/elixir-homepage.md"}] = files

      assert {:ok, saved} = FileManager.read_file(user_id, "research/elixir-homepage.md")
      assert saved =~ "source_url:"
      assert saved =~ "final_url:"
      assert String.length(saved) > 200
    end

    @tag :integration
    test "web.search citations can be chained into web.fetch", context do
      require_api_key!(context)

      user_id = "integration-search-to-fetch"

      search_context = %Context{
        conversation_id: Ecto.UUID.generate(),
        execution_id: Ecto.UUID.generate(),
        user_id: user_id,
        channel: :test,
        integrations: %{openrouter: OpenRouter}
      }

      query =
        "What is the Elixir programming language? Prefer official docs or elixir-lang.org and cite sources."

      log_request("skill.web.search_to_fetch.search", %{
        model: @integration_model,
        query: query,
        provider: "openrouter"
      })

      {search_elapsed, search_result} =
        timed(fn ->
          Search.execute(
            %{
              "query" => query,
              "provider" => "openrouter",
              "model" => @integration_model,
              "limit" => "5",
              "engine" => "native",
              "search_context_size" => "medium"
            },
            search_context
          )
        end)

      assert {:ok, %Result{status: :ok, metadata: metadata}} = search_result
      log_response("skill.web.search_to_fetch.search", {:ok, metadata})
      log_pass("skill.web.search_to_fetch.search", search_elapsed)

      citation_url = pick_preferred_citation_url(metadata.citations)
      assert is_binary(citation_url)

      fetch_context = %Context{
        conversation_id: Ecto.UUID.generate(),
        execution_id: Ecto.UUID.generate(),
        user_id: user_id,
        channel: :test,
        integrations: %{}
      }

      save_to = "research/chained-citation.md"

      log_request("skill.web.search_to_fetch.fetch", %{
        url: citation_url,
        save_to: save_to
      })

      {fetch_elapsed, fetch_result} =
        timed(fn ->
          Fetch.execute(
            %{
              "url" => citation_url,
              "save_to" => save_to,
              "max_chars" => "1500"
            },
            fetch_context
          )
        end)

      assert {:ok,
              %Result{
                status: :ok,
                content: content,
                files_produced: [%{path: ^save_to}],
                metadata: fetch_metadata
              }} = fetch_result

      log_response(
        "skill.web.search_to_fetch.fetch",
        {:ok, %{content: content, metadata: fetch_metadata}}
      )

      log_pass("skill.web.search_to_fetch.fetch", fetch_elapsed)

      assert content =~ "Source:"
      assert is_binary(fetch_metadata.final_url)
      assert {:ok, saved} = FileManager.read_file(user_id, save_to)
      assert saved =~ "source_url:"
      assert saved =~ citation_url
      assert String.length(saved) > 200
    end
  end

  defp require_api_key!(context) do
    if not (is_binary(context.api_key) and context.api_key != "") do
      flunk("Skipped: OPENROUTER_API_KEY not set")
    end
  end

  defp pick_preferred_citation_url(citations) when is_list(citations) do
    preferred_hosts = [
      "elixir-lang.org",
      "hexdocs.pm",
      "phoenixframework.org",
      "hex.pm",
      "erlang.org"
    ]

    citations
    |> Enum.map(&Map.get(&1, :url))
    |> Enum.filter(&usable_citation_url?/1)
    |> Enum.sort_by(&citation_preference_score(&1, preferred_hosts))
    |> List.first()
  end

  defp pick_preferred_citation_url(_), do: nil

  defp usable_citation_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    is_binary(uri.scheme) and is_binary(uri.host) and
      not String.ends_with?(String.downcase(uri.path || ""), ".pdf")
  end

  defp usable_citation_url?(_), do: false

  defp citation_preference_score(url, preferred_hosts) do
    host = URI.parse(url).host || ""

    case Enum.find_index(preferred_hosts, fn preferred ->
           host == preferred or String.ends_with?(host, "." <> preferred)
         end) do
      nil -> {1, host, url}
      idx -> {0, idx, url}
    end
  end
end
