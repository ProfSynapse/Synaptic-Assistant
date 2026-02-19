defmodule AssistantWeb.CoreComponents do
  use Phoenix.Component

  # icon/1 wrapper — re-exports PetalComponents.Icon.icon/1 so that all modules
  # importing CoreComponents (LiveViews, components) get <.icon /> without needing
  # a direct PetalComponents.Icon import. html_helpers nullifies the Petal Icon
  # import to avoid ambiguity (see assistant_web.ex).
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(role aria-hidden)

  def icon(assigns) do
    ~H"""
    <PetalComponents.Icon.icon name={@name} class={@class} {@rest} />
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

  attr :target, :string, required: true, doc: "ID of the contenteditable element this toolbar controls"
  attr :label, :string, default: "Text formatting", doc: "Accessible label for the toolbar"

  def editor_toolbar(assigns) do
    ~H"""
    <div class="sa-editor-toolbar" role="toolbar" aria-label={@label}>
      <div class="sa-toolbar-group sa-toolbar-group-heading">
        <select
          class="sa-toolbar-select"
          data-editor-target={@target}
          data-editor-cmd="heading"
          aria-label="Heading level"
        >
          <option value="p">Paragraph</option>
          <option value="h1">Heading 1</option>
          <option value="h2">Heading 2</option>
          <option value="h3">Heading 3</option>
        </select>
      </div>

      <div class="sa-toolbar-group">
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="bold" aria-label="Bold" title="Bold">
          <PetalComponents.Icon.icon name="hero-bold" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="italic" aria-label="Italic" title="Italic">
          <PetalComponents.Icon.icon name="hero-italic" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="underline" aria-label="Underline" title="Underline">
          <PetalComponents.Icon.icon name="hero-underline" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="ul" aria-label="Bulleted list" title="Bulleted list">
          <PetalComponents.Icon.icon name="hero-list-bullet" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="ol" aria-label="Numbered list" title="Numbered list">
          <PetalComponents.Icon.icon name="hero-numbered-list" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="link" aria-label="Insert link" title="Insert link">
          <PetalComponents.Icon.icon name="hero-link" class="h-4 w-4" />
        </button>
        <button type="button" class="sa-icon-btn sa-toolbar-btn" data-editor-target={@target} data-editor-cmd="code" aria-label="Inline code" title="Inline code">
          <PetalComponents.Icon.icon name="hero-code-bracket" class="h-4 w-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc false
  def translate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  def translate_error(message) when is_binary(message), do: message
end
