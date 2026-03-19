defmodule Assistant.Billing.StorageAccounting do
  @moduledoc false

  @spec synced_file_growth(binary() | nil, binary() | nil) :: non_neg_integer()
  def synced_file_growth(existing_content, new_content) do
    retained_growth(byte_size_or_zero(existing_content), byte_size_or_zero(new_content))
  end

  @spec message_retained_bytes(map()) :: non_neg_integer()
  def message_retained_bytes(attrs) when is_map(attrs) do
    [
      byte_size_or_zero(get_attr(attrs, :content)),
      json_size(get_attr(attrs, :content_encrypted)),
      json_size(get_attr(attrs, :tool_calls)),
      json_size(get_attr(attrs, :tool_results))
    ]
    |> Enum.sum()
  end

  @spec memory_entry_retained_bytes(map()) :: non_neg_integer()
  def memory_entry_retained_bytes(attrs) when is_map(attrs) do
    byte_size_or_zero(get_attr(attrs, :title)) + byte_size_or_zero(get_attr(attrs, :content))
  end

  @spec memory_entry_growth(struct(), map()) :: non_neg_integer()
  def memory_entry_growth(existing, attrs) when is_map(attrs) do
    next_title = get_attr(attrs, :title) || Map.get(existing, :title)
    next_content = get_attr(attrs, :content) || Map.get(existing, :content)

    retained_growth(
      byte_size_or_zero(Map.get(existing, :title)) +
        byte_size_or_zero(Map.get(existing, :content)),
      byte_size_or_zero(next_title) + byte_size_or_zero(next_content)
    )
  end

  defmacro message_size_expr(
             content_field,
             content_encrypted_field,
             tool_calls_field,
             tool_results_field
           ) do
    quote do
      fragment(
        "coalesce(octet_length(?), 0) + coalesce(octet_length(to_jsonb(?)::text), 0) + coalesce(octet_length(to_jsonb(?)::text), 0) + coalesce(octet_length(to_jsonb(?)::text), 0)",
        unquote(content_field),
        unquote(content_encrypted_field),
        unquote(tool_calls_field),
        unquote(tool_results_field)
      )
    end
  end

  defmacro memory_entry_size_expr(title_field, content_field) do
    quote do
      fragment(
        "coalesce(octet_length(?), 0) + coalesce(octet_length(?), 0)",
        unquote(title_field),
        unquote(content_field)
      )
    end
  end

  def humanize_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_000_000_000 -> format_units(bytes, 1_000_000_000, "GB")
      bytes >= 1_000_000 -> format_units(bytes, 1_000_000, "MB")
      bytes >= 1_000 -> format_units(bytes, 1_000, "KB")
      true -> "#{bytes} B"
    end
  end

  def humanize_bytes(_), do: nil

  defp retained_growth(existing_size, new_size)
       when is_integer(existing_size) and is_integer(new_size) do
    max(new_size - existing_size, 0)
  end

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp json_size(nil), do: 0

  defp json_size(value) do
    value
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  rescue
    _ -> 0
  end

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp format_units(bytes, divisor, unit) do
    value = bytes / divisor

    label =
      if value == trunc(value) do
        Integer.to_string(trunc(value))
      else
        :erlang.float_to_binary(Float.round(value, 1), decimals: 1)
      end

    "#{label} #{unit}"
  end
end
