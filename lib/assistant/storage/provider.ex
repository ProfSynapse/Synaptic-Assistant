defmodule Assistant.Storage.Provider do
  @moduledoc """
  Behaviour for provider-specific storage source and tree browsing.
  """

  alias Assistant.Storage.{Node, Source}

  @type provider_result :: {:ok, term()} | {:error, term()}

  @callback list_sources(binary(), keyword()) :: provider_result()
  @callback search_sources(binary(), String.t(), keyword()) :: provider_result()
  @callback get_source(binary(), String.t(), keyword()) :: provider_result()
  @callback list_children(binary(), Source.t(), String.t() | :root | nil, keyword()) ::
              {:ok, %{items: [Node.t()], next_cursor: term() | nil, complete?: boolean()}}
              | {:error, term()}
  @callback get_delta_cursor(binary(), Source.t(), keyword()) :: provider_result()
  @callback normalize_file_kind(map()) :: String.t()
  @callback capabilities() :: map()
end
