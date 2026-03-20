defmodule Assistant.Skills.Web.FetchTest do
  use Assistant.DataCase, async: false
  @moduletag :external

  alias Assistant.Skills.Context
  alias Assistant.Skills.Result
  alias Assistant.Skills.Web.Fetch
  alias Assistant.Schemas.{SyncedFile, User}
  alias Assistant.Sync.FileManager

  defmodule FetcherStub do
    def fetch(url) do
      send(self(), {:fetch, url})

      {:ok,
       %{
         url: url,
         final_url: url,
         status: 200,
         content_type: "text/html",
         fetched_at: ~U[2026-03-04 12:00:00Z],
         body:
           "<html><head><title>Example</title></head><body><article>Hello world</article></body></html>",
         headers: %{}
       }}
    end
  end

  defmodule ExtractorStub do
    def extract(_body, opts) do
      send(self(), {:extract, opts})
      {:ok, %{title: "Example", canonical_url: nil, content: "Hello world"}}
    end
  end

  defmodule DisallowedHostFetcherStub do
    def fetch(_url), do: {:error, :disallowed_host}
  end

  defmodule TooLargeFetcherStub do
    def fetch(_url), do: {:error, {:body_too_large, 1024}}
  end

  defmodule RedirectLoopFetcherStub do
    def fetch(_url), do: {:error, {:too_many_redirects, 3}}
  end

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "web_fetch_test_#{System.unique_integer([:positive])}")
    original = Application.get_env(:assistant, :sync_workspace_dir)
    Application.put_env(:assistant, :sync_workspace_dir, tmp_dir)

    on_exit(fn ->
      if original do
        Application.put_env(:assistant, :sync_workspace_dir, original)
      else
        Application.delete_env(:assistant, :sync_workspace_dir)
      end
    end)

    :ok
  end

  test "fetches readable text and saves it to the workspace" do
    user = insert_user("web-fetch")
    insert_synced_file(user.id, "research/example.md")
    context = build_context(user.id)

    assert {:ok, %Result{status: :ok, content: content, files_produced: files}} =
             Fetch.execute(
               %{"url" => "https://example.com", "save_to" => "research/example.md"},
               context
             )

    assert_received {:fetch, "https://example.com"}
    assert_received {:extract, [selector: nil]}
    assert content =~ "Hello world"
    assert [%{path: "research/example.md"}] = files

    assert {:ok, saved} = FileManager.read_file(context.user_id, "research/example.md")
    assert saved =~ "source_url:"
    assert saved =~ "Hello world"
  end

  test "returns an error when url is missing" do
    context = build_context()

    assert {:ok, %Result{status: :error, content: content}} = Fetch.execute(%{}, context)
    assert content =~ "--url"
  end

  test "returns a clear error for disallowed hosts" do
    context = build_context(nil, web_fetcher: DisallowedHostFetcherStub)

    assert {:ok, %Result{status: :error, content: content}} =
             Fetch.execute(%{"url" => "https://blocked.example"}, context)

    assert content =~ "disallowed hosts"
  end

  test "returns a clear error when the fetched page exceeds the size limit" do
    context = build_context(nil, web_fetcher: TooLargeFetcherStub)

    assert {:ok, %Result{status: :error, content: content}} =
             Fetch.execute(%{"url" => "https://example.com/large"}, context)

    assert content =~ "1024 byte limit"
  end

  test "returns a clear error for redirect loops" do
    context = build_context(nil, web_fetcher: RedirectLoopFetcherStub)

    assert {:ok, %Result{status: :error, content: content}} =
             Fetch.execute(%{"url" => "https://example.com/loop"}, context)

    assert content =~ "redirected too many times"
    assert content =~ "3"
  end

  defp build_context(user_id \\ Ecto.UUID.generate(), overrides \\ %{}) do
    overrides = Map.new(overrides)

    %Context{
      conversation_id: Ecto.UUID.generate(),
      execution_id: Ecto.UUID.generate(),
      user_id: user_id,
      integrations:
        Map.merge(
          %{
            web_fetcher: FetcherStub,
            web_extractor: ExtractorStub
          },
          overrides
        )
    }
  end

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp insert_synced_file(user_id, local_path) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SyncedFile{}
    |> SyncedFile.changeset(%{
      user_id: user_id,
      drive_file_id: "drive-#{System.unique_integer([:positive])}",
      drive_file_name: Path.basename(local_path),
      drive_mime_type: "text/markdown",
      local_path: local_path,
      local_format: "md",
      local_modified_at: now,
      remote_modified_at: now,
      sync_status: "synced",
      last_synced_at: now
    })
    |> Repo.insert!()
  end
end
