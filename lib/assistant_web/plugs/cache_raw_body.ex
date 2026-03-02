# lib/assistant_web/plugs/cache_raw_body.ex — Raw body caching for HMAC verification.
#
# Custom body reader for Plug.Parsers that caches the raw request body in
# conn.private[:raw_body]. This is needed for Slack webhook HMAC-SHA256
# verification, which requires access to the raw body after JSON parsing.
#
# Configured as the `body_reader` option on Plug.Parsers in endpoint.ex.
#
# Related files:
#   - lib/assistant_web/endpoint.ex (configured as body_reader)
#   - lib/assistant_web/plugs/slack_auth.ex (reads conn.private[:raw_body])

defmodule AssistantWeb.Plugs.CacheRawBody do
  @moduledoc """
  Custom body reader that caches the raw request body.

  Plug.Parsers consumes the request body during JSON parsing, making it
  unavailable for subsequent plugs. This module provides a `read_body/2`
  function that reads the body and stores a copy in `conn.private[:raw_body]`
  before returning it to Plug.Parsers for normal parsing.

  ## Configuration

  In `endpoint.ex`:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {AssistantWeb.Plugs.CacheRawBody, :read_body, []},
        json_decoder: Phoenix.json_library()
  """

  @doc """
  Read the request body and cache it in conn.private[:raw_body].

  This function has the same signature as `Plug.Conn.read_body/2` and is
  used as a drop-in replacement via the `body_reader` option.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts \\ []) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, partial, conn} ->
        # For large bodies read in chunks, accumulate
        {:more, partial, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
