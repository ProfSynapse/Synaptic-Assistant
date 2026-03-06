defmodule Assistant.Orchestrator.ContextFilesTest do
  use Assistant.DataCase, async: true

  alias Assistant.Orchestrator.ContextFiles
  alias Assistant.Sync.StateStore

  setup do
    user = insert_test_user("context-files")
    %{user: user}
  end

  describe "load/2" do
    test "loads DB-backed text workspace files into the prompt prefix", %{user: user} do
      create_synced_file(user, %{
        drive_file_id: "drive-md",
        drive_file_name: "Notes",
        drive_mime_type: "text/markdown",
        local_path: "notes.md",
        local_format: "md",
        content: "# Launch Notes"
      })

      assert {:ok, payload} =
               ContextFiles.load(["notes.md"],
                 user_id: user.id,
                 provider: :openrouter,
                 budget_tokens: 1_000,
                 model_info: %{input_modalities: [:text]}
               )

      assert payload.prompt_prefix =~ "## Context Documents"
      assert payload.prompt_prefix =~ "### notes.md"
      assert payload.prompt_prefix =~ "# Launch Notes"
      assert payload.messages == []
    end

    test "loads DB-backed images as multimodal message parts for image-capable models", %{
      user: user
    } do
      create_synced_file(user, %{
        drive_file_id: "drive-image",
        drive_file_name: "Diagram",
        drive_mime_type: "image/png",
        local_path: "diagram.png",
        local_format: "png",
        content: "png-bytes"
      })

      assert {:ok, payload} =
               ContextFiles.load(["diagram.png"],
                 user_id: user.id,
                 provider: :openrouter,
                 budget_tokens: 1_000,
                 model_info: %{input_modalities: [:text, :image]}
               )

      assert payload.prompt_prefix == ""
      assert [%{role: "user", content: [intro, image_part]}] = payload.messages
      assert intro.type == "text"
      assert intro.text =~ "diagram.png"
      assert image_part.type == "image_url"
      assert String.starts_with?(image_part.image_url.url, "data:image/png;base64,")
    end

    test "loads PDFs as file parts on the OpenRouter path", %{user: user} do
      create_synced_file(user, %{
        drive_file_id: "drive-pdf",
        drive_file_name: "Plan",
        drive_mime_type: "application/pdf",
        local_path: "plan.pdf",
        local_format: "pdf",
        content: "%PDF-1.7 fake"
      })

      assert {:ok, payload} =
               ContextFiles.load(["plan.pdf"],
                 user_id: user.id,
                 provider: :openrouter,
                 budget_tokens: 1_000,
                 model_info: %{input_modalities: [:text, :document]}
               )

      assert [%{role: "user", content: [intro, file_part]}] = payload.messages
      assert intro.text =~ "plan.pdf"
      assert file_part.type == "file"
      assert file_part.file.filename == "plan.pdf"
      assert String.starts_with?(file_part.file.file_data, "data:application/pdf;base64,")
    end

    test "loads PDFs as file parts on the direct OpenAI path", %{user: user} do
      create_synced_file(user, %{
        drive_file_id: "drive-pdf-openai",
        drive_file_name: "Spec",
        drive_mime_type: "application/pdf",
        local_path: "spec.pdf",
        local_format: "pdf",
        content: "%PDF-1.7 fake"
      })

      assert {:ok, payload} =
               ContextFiles.load(["spec.pdf"],
                 user_id: user.id,
                 provider: :openai,
                 budget_tokens: 1_000,
                 model_info: %{input_modalities: [:text, :document]}
               )

      assert payload.prompt_prefix == ""
      assert [%{role: "user", content: [intro, file_part]}] = payload.messages
      assert intro.text =~ "spec.pdf"
      assert file_part.type == "file"
      assert file_part.file.filename == "spec.pdf"
      assert String.starts_with?(file_part.file.file_data, "data:application/pdf;base64,")
    end

    test "returns a budget error when text context exceeds the allowed token budget", %{
      user: user
    } do
      create_synced_file(user, %{
        drive_file_id: "drive-large",
        drive_file_name: "Large Notes",
        drive_mime_type: "text/plain",
        local_path: "large.txt",
        local_format: "txt",
        content: String.duplicate("abcd", 80)
      })

      assert {:error, {:context_budget_exceeded, details}} =
               ContextFiles.load(["large.txt"],
                 user_id: user.id,
                 provider: :openrouter,
                 budget_tokens: 10,
                 model_info: %{input_modalities: [:text]}
               )

      assert details.budget_tokens == 10
      assert details.estimated_tokens > details.budget_tokens
      assert [%{path: "large.txt"}] = details.files
    end
  end

  defp create_synced_file(user, attrs) do
    defaults = %{
      user_id: user.id,
      remote_modified_at: DateTime.utc_now(),
      local_modified_at: DateTime.utc_now(),
      remote_checksum: "remote-checksum",
      local_checksum: "local-checksum",
      sync_status: "synced",
      last_synced_at: DateTime.utc_now()
    }

    {:ok, synced_file} = StateStore.create_synced_file(Map.merge(defaults, attrs))
    synced_file
  end

  defp insert_test_user(prefix) do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end
end
