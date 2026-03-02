# test/integration/support/test_logger.ex
#
# Shared verbose logging helper for integration tests.
# Provides colored, structured output showing exactly what is sent to the LLM,
# what comes back, and clear pass/fail indicators with timing.
#
# Logging is ON by default when tests run, and can be disabled with:
#   INTEGRATION_LOG=0 mix test --include integration ...
#
# Usage in tests:
#   import Assistant.Integration.TestLogger
#   log_request("sentinel check", %{messages: msgs, model: model})
#   log_response("sentinel check", {:ok, response})
#   log_pass("approves aligned action", elapsed_ms)
#   log_fail("rejects misaligned action", "Expected :rejected, got :approved")

defmodule Assistant.Integration.TestLogger do
  @moduledoc false

  @enabled System.get_env("INTEGRATION_LOG", "1") != "0"

  # ANSI color codes
  @reset "\e[0m"
  @bold "\e[1m"
  @dim "\e[2m"
  @cyan "\e[36m"
  @green "\e[32m"
  @red "\e[31m"
  @yellow "\e[33m"
  @magenta "\e[35m"

  @separator String.duplicate("\u2501", 72)

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Log an outgoing LLM request.
  `label` is a human-readable test/step name.
  `data` is a map/keyword with keys like :model, :messages, :tools, :response_format, :temperature.
  """
  def log_request(label, data) when is_map(data) or is_list(data) do
    if @enabled do
      data = if is_list(data), do: Map.new(data), else: data

      IO.puts("""

      #{@cyan}#{@bold}#{@separator}#{@reset}
      #{@cyan}#{@bold}  REQUEST: #{label}#{@reset}
      #{@cyan}#{@separator}#{@reset}
      #{format_field("Model", data[:model])}#{format_messages(data[:messages])}#{format_tools(data[:tools])}#{format_field("Temperature", data[:temperature])}#{format_field("Max Tokens", data[:max_tokens])}#{format_response_format(data[:response_format])}#{@cyan}#{@separator}#{@reset}
      """)
    end
  end

  def log_request(label, data) do
    if @enabled do
      IO.puts("""

      #{@cyan}#{@bold}#{@separator}#{@reset}
      #{@cyan}#{@bold}  REQUEST: #{label}#{@reset}
      #{@cyan}#{@separator}#{@reset}
      #{@dim}  #{inspect(data, pretty: true, limit: 500)}#{@reset}
      #{@cyan}#{@separator}#{@reset}
      """)
    end
  end

  @doc """
  Log an LLM response.
  `label` is a human-readable test/step name.
  `result` is {:ok, response} | {:error, reason} | {:tool_calls, list} | {:text, string}.
  """
  def log_response(label, result) do
    if @enabled do
      IO.puts("""

      #{@magenta}#{@bold}#{@separator}#{@reset}
      #{@magenta}#{@bold}  RESPONSE: #{label}#{@reset}
      #{@magenta}#{@separator}#{@reset}
      #{format_result(result)}#{@magenta}#{@separator}#{@reset}
      """)
    end
  end

  @doc """
  Log a test passing with elapsed time in milliseconds.
  """
  def log_pass(test_name, elapsed_ms) do
    if @enabled do
      IO.puts("""
      #{@green}#{@bold}  PASSED: #{test_name}#{@reset}  #{@dim}(#{elapsed_ms}ms)#{@reset}
      """)
    end
  end

  @doc """
  Log a test failure with reason.
  """
  def log_fail(test_name, reason) do
    if @enabled do
      IO.puts("""
      #{@red}#{@bold}  FAILED: #{test_name}#{@reset}
      #{@red}  Reason: #{inspect(reason, pretty: true, limit: 300)}#{@reset}
      """)
    end
  end

  @doc """
  Time a block and return {elapsed_ms, result}.
  Usage:
    {ms, result} = timed(fn -> some_llm_call() end)
  """
  def timed(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {elapsed, result}
  end

  # -------------------------------------------------------------------
  # Formatting helpers
  # -------------------------------------------------------------------

  defp format_field(_label, nil), do: ""

  defp format_field(label, value) do
    "  #{@bold}#{label}:#{@reset} #{inspect(value)}\n"
  end

  defp format_messages(nil), do: ""

  defp format_messages(messages) when is_list(messages) do
    header = "  #{@bold}Messages:#{@reset} (#{length(messages)})\n"

    body =
      messages
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {msg, i} ->
        role = msg[:role] || msg["role"] || "?"
        content = msg[:content] || msg["content"] || ""
        truncated = truncate(content, 200)
        "    #{@dim}[#{i}] #{String.upcase(to_string(role))}:#{@reset} #{truncated}"
      end)

    header <> body <> "\n"
  end

  defp format_tools(nil), do: ""
  defp format_tools([]), do: ""

  defp format_tools(tools) when is_list(tools) do
    names =
      Enum.map(tools, fn tool ->
        get_in(tool, [:function, :name]) ||
          get_in(tool, ["function", "name"]) ||
          "?"
      end)

    "  #{@bold}Tools:#{@reset} #{Enum.join(names, ", ")}\n"
  end

  defp format_response_format(nil), do: ""

  defp format_response_format(%{type: "json_schema", json_schema: %{name: name}}) do
    "  #{@bold}Response Format:#{@reset} json_schema (#{name})\n"
  end

  defp format_response_format(fmt) do
    "  #{@bold}Response Format:#{@reset} #{inspect(fmt, limit: 100)}\n"
  end

  defp format_result({:ok, %{content: content, tool_calls: tool_calls}})
       when is_list(tool_calls) and tool_calls != [] do
    tc_summary =
      Enum.map_join(tool_calls, "\n", fn tc ->
        name =
          get_in(tc, [:function, :name]) ||
            get_in(tc, ["function", "name"]) ||
            "?"

        args =
          get_in(tc, [:function, :arguments]) ||
            get_in(tc, ["function", "arguments"]) ||
            "{}"

        args_str = if is_binary(args), do: truncate(args, 150), else: truncate(inspect(args), 150)
        "    #{@yellow}#{name}#{@reset}(#{args_str})"
      end)

    content_line = if content, do: "  #{@bold}Content:#{@reset} #{truncate(content, 200)}\n", else: ""

    content_line <>
      "  #{@bold}Tool Calls:#{@reset} (#{length(tool_calls)})\n" <>
      tc_summary <> "\n"
  end

  defp format_result({:ok, %{content: content}}) when is_binary(content) do
    "  #{@bold}Content:#{@reset}\n    #{truncate(content, 500)}\n"
  end

  defp format_result({:ok, parsed}) when is_map(parsed) do
    "  #{@bold}Parsed:#{@reset}\n    #{inspect(parsed, pretty: true, limit: 300)}\n"
  end

  defp format_result({:tool_calls, tool_calls}) when is_list(tool_calls) do
    tc_summary =
      Enum.map_join(tool_calls, "\n", fn tc ->
        name =
          get_in(tc, [:function, :name]) ||
            get_in(tc, ["function", "name"]) ||
            "?"

        args =
          get_in(tc, [:function, :arguments]) ||
            get_in(tc, ["function", "arguments"]) ||
            "{}"

        args_str = if is_binary(args), do: truncate(args, 150), else: truncate(inspect(args), 150)
        "    #{@yellow}#{name}#{@reset}(#{args_str})"
      end)

    "  #{@bold}Tool Calls:#{@reset} (#{length(tool_calls)})\n" <> tc_summary <> "\n"
  end

  defp format_result({:text, text}) when is_binary(text) do
    "  #{@bold}Text:#{@reset}\n    #{truncate(text, 500)}\n"
  end

  defp format_result({:tool_call, skill_name, args}) do
    "  #{@bold}Skill Call:#{@reset} #{@yellow}#{skill_name}#{@reset}\n" <>
      "  #{@bold}Args:#{@reset} #{inspect(args, pretty: true, limit: 200)}\n"
  end

  defp format_result({:error, reason}) do
    "  #{@red}#{@bold}ERROR:#{@reset} #{inspect(reason, pretty: true, limit: 300)}\n"
  end

  defp format_result(other) do
    "  #{inspect(other, pretty: true, limit: 300)}\n"
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text
end
