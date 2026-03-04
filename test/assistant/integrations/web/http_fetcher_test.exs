defmodule Assistant.Integrations.Web.HttpFetcherTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.Web.HttpFetcher

  defmodule UrlPolicyStub do
    def validate("https://blocked.example/internal"), do: {:error, :disallowed_host}
    def validate(url) when is_binary(url), do: {:ok, URI.parse(url)}
  end

  defmodule RobotsStub do
    def allowed?(url, opts) do
      send(self(), {:robots_checked, url, opts})
      {:ok, true}
    end
  end

  test "follows safe redirects, re-checks robots, and records the final url" do
    request_fun = fn
      "https://public.example/start", opts ->
        send(self(), {:request, "https://public.example/start", opts})

        {:ok,
         %Req.Response{
           status: 302,
           headers: %{"location" => ["https://docs.example/final"]},
           body: ""
         }}

      "https://docs.example/final", opts ->
        send(self(), {:request, "https://docs.example/final", opts})

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["text/html"]},
           body: "<html><body>Hello</body></html>"
         }}
    end

    assert {:ok, fetched} =
             HttpFetcher.fetch("https://public.example/start",
               url_policy: UrlPolicyStub,
               robots: RobotsStub,
               request_fun: request_fun,
               max_redirects: 3
             )

    assert fetched.url == "https://public.example/start"
    assert fetched.final_url == "https://docs.example/final"
    assert fetched.status == 200
    assert fetched.content_type == "text/html"

    assert_received {:request, "https://public.example/start", request_opts}
    assert request_opts[:redirect] == false

    assert_received {:request, "https://docs.example/final", redirected_request_opts}
    assert redirected_request_opts[:redirect] == false

    assert_received {:robots_checked, "https://public.example/start", _}
    assert_received {:robots_checked, "https://docs.example/final", _}
  end

  test "blocks redirects to disallowed hosts" do
    request_fun = fn
      "https://public.example/start", _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           headers: %{"location" => ["https://blocked.example/internal"]},
           body: ""
         }}
    end

    assert {:error, :disallowed_host} =
             HttpFetcher.fetch("https://public.example/start",
               url_policy: UrlPolicyStub,
               robots: RobotsStub,
               request_fun: request_fun
             )
  end

  test "returns an error for redirects without a location header" do
    request_fun = fn
      "https://public.example/start", _opts ->
        {:ok, %Req.Response{status: 302, headers: %{}, body: ""}}
    end

    assert {:error, {:redirect_missing_location, 302}} =
             HttpFetcher.fetch("https://public.example/start",
               url_policy: UrlPolicyStub,
               robots: RobotsStub,
               request_fun: request_fun
             )
  end

  test "returns an error after too many redirects" do
    request_fun = fn
      "https://public.example/start", _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           headers: %{"location" => ["https://public.example/step-1"]},
           body: ""
         }}

      "https://public.example/step-1", _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           headers: %{"location" => ["https://public.example/step-2"]},
           body: ""
         }}
    end

    assert {:error, {:too_many_redirects, 1}} =
             HttpFetcher.fetch("https://public.example/start",
               url_policy: UrlPolicyStub,
               robots: RobotsStub,
               request_fun: request_fun,
               max_redirects: 1
             )
  end
end
