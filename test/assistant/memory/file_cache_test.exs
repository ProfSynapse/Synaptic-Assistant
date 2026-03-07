# test/assistant/memory/file_cache_test.exs — Tests for Memory.FileCache module.

defmodule Assistant.Memory.FileCacheTest do
  use ExUnit.Case, async: true

  alias Assistant.Memory.FileCache

  describe "module compilation" do
    test "FileCache module is loaded and exports cache_file/4" do
      assert function_exported?(FileCache, :cache_file, 4)
    end
  end
end
