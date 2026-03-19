defmodule Assistant.Embeddings.ServingTest do
  use ExUnit.Case, async: true

  alias Assistant.Embeddings.Serving

  describe "module compilation" do
    test "module is loaded" do
      assert Code.ensure_loaded?(Serving)
    end

    test "exports child_spec/1" do
      Code.ensure_loaded!(Serving)
      assert function_exported?(Serving, :child_spec, 1)
    end
  end
end
