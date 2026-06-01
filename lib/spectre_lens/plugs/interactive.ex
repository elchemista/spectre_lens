defmodule SpectreLens.Plugs.Interactive do
  @moduledoc """
  Adds non-link interactive controls to the current page view.

  Links are filtered out here because navigation targets are collected by
  `SpectreLens.Plugs.Links`, giving agents separate lists for controls and
  destinations.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.MapHelpers
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :interactive) do
      Helpers.collect(context, :interactive, fn -> collect_interactive(context, opts) end)
    else
      context
    end
  end

  @spec collect_interactive(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp collect_interactive(%Context{} = context, opts) do
    with {:ok, elements} <- SpectreLens.Protocol.interactive_elements(context.tab, opts) do
      {:ok, Enum.reject(elements, &MapHelpers.link?/1)}
    end
  end
end
