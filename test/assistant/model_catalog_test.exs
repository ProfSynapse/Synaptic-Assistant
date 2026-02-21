defmodule Assistant.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias Assistant.ModelCatalog

  setup do
    original_path = Application.get_env(:assistant, :model_catalog_path)
    tmp_dir = Path.join(System.tmp_dir!(), "assistant-model-catalog-tests")
    File.mkdir_p!(tmp_dir)
    tmp_path = Path.join(tmp_dir, "model_catalog_#{System.unique_integer([:positive])}.json")

    Application.put_env(:assistant, :model_catalog_path, tmp_path)

    on_exit(fn ->
      if original_path do
        Application.put_env(:assistant, :model_catalog_path, original_path)
      else
        Application.delete_env(:assistant, :model_catalog_path)
      end

      File.rm(tmp_path)
    end)

    :ok
  end

  test "add_model and remove_model manage catalog entries" do
    attrs = %{
      "id" => "openai/gpt-5.3-codex",
      "name" => "OpenAI GPT-5.3 Codex",
      "input_cost" => "$1.00 / 1M tokens",
      "output_cost" => "$4.00 / 1M tokens",
      "max_context_tokens" => "200000"
    }

    assert {:ok, model} = ModelCatalog.add_model(attrs)
    assert model.id == "openai/gpt-5.3-codex"
    assert {:ok, _} = ModelCatalog.get_model("openai/gpt-5.3-codex")

    assert :ok = ModelCatalog.remove_model("openai/gpt-5.3-codex")
    assert {:error, :not_found} = ModelCatalog.get_model("openai/gpt-5.3-codex")

    assert {:ok, _} = ModelCatalog.add_model(attrs)
    assert {:ok, _} = ModelCatalog.get_model("openai/gpt-5.3-codex")
  end

  test "read legacy catalog format without removed_model_ids" do
    path = Application.get_env(:assistant, :model_catalog_path)

    payload = %{
      "models" => [
        %{
          "id" => "anthropic/claude-sonnet-4.6",
          "name" => "Claude Sonnet 4.6",
          "input_cost" => "$3.00 / 1M tokens",
          "output_cost" => "$15.00 / 1M tokens",
          "max_context_tokens" => "200000"
        }
      ]
    }

    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))

    assert {:ok, model} = ModelCatalog.get_model("anthropic/claude-sonnet-4.6")
    assert model.name == "Claude Sonnet 4.6"
  end
end
