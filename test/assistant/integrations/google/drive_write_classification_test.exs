defmodule Assistant.Integrations.Google.DriveWriteClassificationTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.Google.Drive

  describe "classify_write_error/1" do
    test "classifies 409 as conflict" do
      assert :conflict = Drive.classify_write_error(%Tesla.Env{status: 409})
    end

    test "classifies 412 as conflict" do
      assert :conflict = Drive.classify_write_error(%Tesla.Env{status: 412})
    end

    test "classifies 429 as transient" do
      assert :transient = Drive.classify_write_error(%Tesla.Env{status: 429})
    end

    test "classifies 5xx as transient" do
      assert :transient = Drive.classify_write_error(%Tesla.Env{status: 500})
      assert :transient = Drive.classify_write_error(%Tesla.Env{status: 503})
    end

    test "classifies timeout as transient" do
      assert :transient = Drive.classify_write_error(:timeout)
    end

    test "classifies unknown errors as fatal" do
      assert :fatal = Drive.classify_write_error(%Tesla.Env{status: 400})
      assert :fatal = Drive.classify_write_error(:unexpected)
    end
  end
end
