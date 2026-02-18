# lib/assistant/skills/skill_definition.ex — Parsed skill file representation.
#
# Created by the Loader when it reads a skill markdown file from disk.
# Stored in the ETS registry keyed by name (e.g., "email.send").
# Contains both the YAML frontmatter fields and the raw markdown body.

defmodule Assistant.Skills.SkillDefinition do
  @moduledoc """
  Represents a parsed skill markdown file.

  The YAML frontmatter provides machine-readable routing fields
  (`name`, `description`, `handler`). The markdown `body` is the
  full skill definition served as help text and used by handlers.

  ## Fields

    * `:name` - Dot-notation skill name (e.g., "email.send")
    * `:description` - One-line summary for listings and search
    * `:domain` - Derived from directory path, not YAML
    * `:handler` - Elixir module that executes the skill (nil for custom/template skills)
    * `:schedule` - Cron expression for Quantum (optional)
    * `:tags` - Searchable tags for skill discovery
    * `:author` - Who created the skill (optional, for custom skills)
    * `:timezone` - Default timezone override for scheduled execution (optional)
    * `:body` - Raw markdown body (everything after YAML frontmatter)
    * `:path` - Absolute filesystem path to the source .md file
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          domain: String.t(),
          handler: module() | nil,
          schedule: String.t() | nil,
          tags: [String.t()],
          author: String.t() | nil,
          timezone: String.t() | nil,
          body: String.t(),
          path: String.t()
        }

  @enforce_keys [:name, :description, :domain, :body, :path]
  defstruct [
    :name,
    :description,
    :domain,
    :handler,
    :schedule,
    :author,
    :timezone,
    :body,
    :path,
    tags: []
  ]
end
