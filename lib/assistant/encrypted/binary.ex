# lib/assistant/encrypted/binary.ex — Cloak-encrypted binary Ecto type.
#
# Wraps Cloak.Ecto.Binary with the project's Assistant.Vault for transparent
# AES-GCM encryption/decryption of binary fields at rest.
#
# Related files:
#   - lib/assistant/vault.ex (Cloak vault with cipher config)
#   - lib/assistant/schemas/notification_channel.ex (uses this type for config field)

defmodule Assistant.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: Assistant.Vault
end
