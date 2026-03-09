defmodule Assistant.Storage.Node do
  @moduledoc """
  Normalized storage browser node.
  """

  @enforce_keys [:provider, :source_id, :node_id, :name, :node_type]
  defstruct [
    :provider,
    :source_id,
    :node_id,
    :parent_node_id,
    :name,
    :node_type,
    :file_kind,
    :mime_type,
    provider_metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom() | String.t(),
          source_id: String.t(),
          node_id: String.t(),
          parent_node_id: String.t() | nil,
          name: String.t(),
          node_type: :container | :file | :link,
          file_kind: String.t() | nil,
          mime_type: String.t() | nil,
          provider_metadata: map()
        }
end
