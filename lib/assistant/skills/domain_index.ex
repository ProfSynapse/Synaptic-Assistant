# lib/assistant/skills/domain_index.ex — Parsed SKILL.md domain index.
#
# Created by the Loader when it reads a SKILL.md file from a domain
# directory. Provides the progressive-disclosure bridge between
# "list all domains" and "show me a specific skill."

defmodule Assistant.Skills.DomainIndex do
  @moduledoc """
  Represents a parsed SKILL.md domain index file.

  Each domain directory (e.g., `skills/email/`) contains a `SKILL.md`
  that describes the domain and lists its available skills.

  ## Fields

    * `:domain` - Domain name (e.g., "email", "tasks")
    * `:description` - One-line domain summary
    * `:body` - Full markdown body of the SKILL.md file
    * `:path` - Absolute filesystem path to the SKILL.md file
  """

  @type t :: %__MODULE__{
          domain: String.t(),
          description: String.t(),
          body: String.t(),
          path: String.t()
        }

  @enforce_keys [:domain, :description, :body, :path]
  defstruct [:domain, :description, :body, :path]
end
