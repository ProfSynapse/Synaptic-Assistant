defmodule Assistant.Storage.Source do
  @moduledoc """
  Normalized top-level browsable storage source.
  """

  @enforce_keys [:provider, :source_id, :source_type, :label]
  defstruct [
    :provider,
    :source_id,
    :source_type,
    :label,
    capabilities: %{},
    provider_metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom() | String.t(),
          source_id: String.t(),
          source_type: String.t(),
          label: String.t(),
          capabilities: map(),
          provider_metadata: map()
        }
end
