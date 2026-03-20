defmodule Assistant.Integrations.Web.UrlPolicyTest do
  use ExUnit.Case, async: true
  @moduletag :external

  alias Assistant.Integrations.Web.UrlPolicy

  test "allows a public ipv4 address over https" do
    assert {:ok, %URI{scheme: "https", host: "1.1.1.1"}} =
             UrlPolicy.validate("https://1.1.1.1/")
  end

  test "rejects localhost" do
    assert {:error, :disallowed_host} = UrlPolicy.validate("http://localhost:4000/")
  end

  test "rejects private ipv4 ranges" do
    assert {:error, :disallowed_host} = UrlPolicy.validate("http://10.0.0.5/")
    assert {:error, :disallowed_host} = UrlPolicy.validate("http://172.16.10.20/")
    assert {:error, :disallowed_host} = UrlPolicy.validate("http://192.168.1.25/")
  end

  test "rejects unsupported schemes" do
    assert {:error, :unsupported_scheme} = UrlPolicy.validate("file:///etc/passwd")
  end

  test "rejects missing host" do
    assert {:error, :missing_host} = UrlPolicy.validate("https:///missing-host")
  end
end
