# lib/assistant/vault.ex — Cloak vault for Ecto field encryption.
#
# AES-GCM encryption vault used by Cloak.Ecto to transparently encrypt/decrypt
# sensitive fields at rest (e.g., webhook URLs in notification_channels.config).
#
# Configuration is in config/runtime.exs via the CLOAK_ENCRYPTION_KEY env var.
#
# Related files:
#   - config/runtime.exs (cipher configuration)
#   - lib/assistant/schemas/notification_channel.ex (encrypted config field)

defmodule Assistant.Vault do
  use Cloak.Vault, otp_app: :assistant
end
