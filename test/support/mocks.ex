# test/support/mocks.ex — Mox mock definitions for test environment.
#
# Defines mock modules for behaviours used across the application.
# These mocks are configured as the default implementations in config/test.exs
# so that @llm_client compile_env resolves to the mock in test builds.

Mox.defmock(MockLLMClient, for: Assistant.Behaviours.LLMClient)
