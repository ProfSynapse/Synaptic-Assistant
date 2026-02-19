# lib/assistant_web.ex — Web module for the AssistantWeb namespace.
#
# Provides macros for controllers, routers, and other web components.
# This is a webhooks-only Phoenix application — no HTML views or LiveView.

defmodule AssistantWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use AssistantWeb, :controller
      use AssistantWeb, :router
  """

  def static_paths, do: ~w(robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AssistantWeb.Endpoint,
        router: AssistantWeb.Router,
        statics: AssistantWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/router/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
