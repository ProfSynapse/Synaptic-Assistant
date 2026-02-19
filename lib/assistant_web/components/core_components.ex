defmodule AssistantWeb.CoreComponents do
  use Phoenix.Component

  attr :name, :string, required: true
  attr :class, :string, default: "h-5 w-5"

  def icon(assigns) do
    ~H"""
    <%= case @name do %>
      <% "hero-bars-3" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5" />
        </svg>
      <% "hero-home" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m2.25 12 8.954-8.955a1.125 1.125 0 0 1 1.592 0L21.75 12M4.5 9.75V19.5A2.25 2.25 0 0 0 6.75 21.75h10.5A2.25 2.25 0 0 0 19.5 19.5V9.75" />
        </svg>
      <% "hero-user-circle" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M17.982 18.725A7.488 7.488 0 0 0 12 15.75a7.488 7.488 0 0 0-5.982 2.975m11.964 0a9 9 0 1 0-11.964 0m11.964 0A8.966 8.966 0 0 1 12 21a8.966 8.966 0 0 1-5.982-2.275M15 9.75a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
        </svg>
      <% "hero-cube" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m21 7.5-9-5.25-9 5.25m18 0v9l-9 5.25m9-14.25-9 5.25m0 0L3 7.5m9 5.25v9" />
        </svg>
      <% "hero-chart-bar" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M3 3v18h18M7.5 15V9m4.5 6V6m4.5 9v-3" />
        </svg>
      <% "hero-document-text" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M19.5 14.25v-9A2.25 2.25 0 0 0 17.25 3h-10.5A2.25 2.25 0 0 0 4.5 5.25v13.5A2.25 2.25 0 0 0 6.75 21h10.5A2.25 2.25 0 0 0 19.5 18.75V17.25M8.25 7.5h7.5M8.25 11.25h7.5M8.25 15h4.5" />
        </svg>
      <% "hero-puzzle-piece" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M14.25 6.087c0-.925-.75-1.675-1.675-1.675h-1.15A2.925 2.925 0 0 0 8.5 7.337V8.25H6.75A2.25 2.25 0 0 0 4.5 10.5v1.75h.913a2.925 2.925 0 0 1 2.925 2.925v1.15c0 .925.75 1.675 1.675 1.675h1.15a2.925 2.925 0 0 0 2.925-2.925V14.25h1.75A2.25 2.25 0 0 0 18 12V10.5a2.25 2.25 0 0 0-2.25-2.25h-1.5V6.087Z" />
        </svg>
      <% "hero-command-line" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m6.75 7.5 3 3-3 3m4.5 3h6.75M3 5.25A2.25 2.25 0 0 1 5.25 3h13.5A2.25 2.25 0 0 1 21 5.25v13.5A2.25 2.25 0 0 1 18.75 21H5.25A2.25 2.25 0 0 1 3 18.75V5.25Z" />
        </svg>
      <% "hero-wrench-screwdriver" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m11.42 3.17 2.12 2.121a3 3 0 0 1-2.123 5.121H9.75l-6 6a1.5 1.5 0 0 0 2.122 2.122l6-6v-1.67a3 3 0 0 1 5.121-2.122l2.122 2.122M15 6l3-3m0 0h3m-3 0v3" />
        </svg>
      <% "hero-question-mark-circle" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 18h.01M9.75 9.75a2.25 2.25 0 1 1 4.5 0c0 .84-.47 1.386-1.08 1.882-.6.488-1.17.918-1.17 1.868m9-1.5a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
        </svg>
      <% "hero-information-circle" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M11.25 11.25h1.5v4.5h-1.5m0-8.25h1.5m9 4.5a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
        </svg>
      <% "hero-chevron-double-left" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m11.25 6.75-4.5 5.25 4.5 5.25m6-10.5-4.5 5.25 4.5 5.25" />
        </svg>
      <% "hero-chevron-double-right" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m6.75 6.75 4.5 5.25-4.5 5.25m6-10.5 4.5 5.25-4.5 5.25" />
        </svg>
      <% "hero-pencil-square" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M16.862 4.487a2.121 2.121 0 1 1 3 3L7.5 19.85l-4.5 1.5 1.5-4.5L16.862 4.487ZM19.5 14.25v3.75a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18V6A2.25 2.25 0 0 1 6 3.75h3.75" />
        </svg>
      <% "hero-document-duplicate" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15.75 17.25v1.5A2.25 2.25 0 0 1 13.5 21h-7.5a2.25 2.25 0 0 1-2.25-2.25v-10.5A2.25 2.25 0 0 1 6 6h1.5m8.25 11.25h1.5A2.25 2.25 0 0 0 19.5 15V4.5A2.25 2.25 0 0 0 17.25 2.25h-7.5A2.25 2.25 0 0 0 7.5 4.5V6m8.25 11.25h-6A2.25 2.25 0 0 1 7.5 15V6m8.25 11.25V6" />
        </svg>
      <% "hero-plus" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
      <% "hero-x-mark" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M6 18 18 6M6 6l12 12" />
        </svg>
      <% "hero-arrow-path" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M16.023 9.348h4.992v-.001M7.977 14.652H2.985v.001m0 0h4.992m-4.992 0V9.75m18.038 4.902a9 9 0 0 0-15.518-5.476l-2.52 2.52m18.038 2.956a9 9 0 0 1-15.518 5.476l-2.52-2.52" />
        </svg>
      <% "hero-bold" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M7 5h5a3 3 0 1 1 0 6H7m0 0h6a3 3 0 1 1 0 6H7V5Z" />
        </svg>
      <% "hero-italic" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M10 4h8M6 20h8m2-16-4 16" />
        </svg>
      <% "hero-list-bullet" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M9 6h10M9 12h10M9 18h10" />
          <circle cx="4.5" cy="6" r="1" fill="currentColor" stroke="none" />
          <circle cx="4.5" cy="12" r="1" fill="currentColor" stroke="none" />
          <circle cx="4.5" cy="18" r="1" fill="currentColor" stroke="none" />
        </svg>
      <% "hero-numbered-list" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M9 6h10M9 12h10M9 18h10" />
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M3.5 5h2v2h-2zm0 6h2v2h-2zm0 6h2v2h-2z" />
        </svg>
      <% "hero-link" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M10 14a3 3 0 0 1 0-4.243l2.121-2.121a3 3 0 1 1 4.243 4.243L15 13m-1 1a3 3 0 0 1 0 4.243l-2.121 2.121a3 3 0 1 1-4.243-4.243L9 15" />
        </svg>
      <% "hero-code-bracket" -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="m8 8-4 4 4 4m8-8 4 4-4 4" />
        </svg>
      <% _ -> %>
        <svg xmlns="http://www.w3.org/2000/svg" class={@class} fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <circle cx="12" cy="12" r="9" stroke-width="1.5"></circle>
        </svg>
    <% end %>
    """
  end

  attr :type, :string, default: "text"
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :errors, :list, default: []
  attr :checked, :boolean, default: false
  attr :options, :list, default: []
  attr :multiple, :boolean, default: false
  attr :prompt, :string, default: nil
  attr :class, :string, default: nil

  attr :rest, :global,
    include:
      ~w(accept autocomplete cols disabled form max maxlength min minlength pattern placeholder readonly required rows step phx-debounce)

  def input(assigns) do
    assigns =
      if assigns.field do
        assign(assigns,
          id: assigns.id || assigns.field.id,
          name: assigns.name || assigns.field.name,
          value: if(is_nil(assigns.value), do: assigns.field.value, else: assigns.value),
          errors: if(assigns.errors == [], do: assigns.field.errors, else: assigns.errors)
        )
      else
        assign(assigns, :id, assigns.id || assigns.name)
      end

    assigns = assign(assigns, :errors, Enum.map(assigns.errors, &translate_error/1))

    ~H"""
    <div class="sa-field">
      <label :if={@label} for={@id} class="sa-label">{@label}</label>

      <input
        :if={@type not in ["textarea", "select", "checkbox"]}
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        class={["sa-input", @class]}
        {@rest}
      />

      <textarea
        :if={@type == "textarea"}
        id={@id}
        name={@name}
        class={["sa-input sa-textarea", @class]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>

      <select
        :if={@type == "select"}
        id={@id}
        name={@name}
        class={["sa-input", @class]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        <option
          :for={{option_label, option_value} <- @options}
          value={option_value}
          selected={selected?(@value, option_value, @multiple)}
        >
          {option_label}
        </option>
      </select>

      <div :if={@type == "checkbox"} class="sa-checkbox-row">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked || checked_value?(@value)}
          class="sa-checkbox"
          {@rest}
        />
      </div>

      <p :for={error <- @errors} class="sa-field-error">{error}</p>
    </div>
    """
  end

  attr :type, :string, default: "submit"
  attr :class, :string, default: nil
  attr :variant, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["sa-btn", @class]}
      data-variant={@variant}
      name={@name}
      value={@value}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  slot :inner_block, required: true
  slot :subtitle

  def header(assigns) do
    ~H"""
    <header class="sa-header">
      <h1 class="sa-title">{render_slot(@inner_block)}</h1>
      <p :if={@subtitle != []} class="sa-muted">{render_slot(@subtitle)}</p>
    </header>
    """
  end

  defp selected?(value, option_value, true) when is_list(value), do: option_value in value
  defp selected?(value, option_value, false), do: to_string(value) == to_string(option_value)
  defp selected?(_, _, _), do: false

  defp checked_value?(value), do: value in [true, "true", "on", "1", 1]

  defp translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  defp translate_error(message) when is_binary(message), do: message
end
