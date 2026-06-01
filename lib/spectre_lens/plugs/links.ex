defmodule SpectreLens.Plugs.Links do
  @moduledoc """
  Adds deduplicated navigation links to a page view.

  Links are keyed by `href` when available so repeated navigation labels do not
  flood the agent-facing view.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.MapHelpers
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :links) do
      Helpers.collect(context, :links, fn -> collect_links(context, opts) end)
    else
      context
    end
  end

  @spec collect_links(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp collect_links(%Context{} = context, opts) do
    with {:ok, links} <- SpectreLens.Protocol.links(context.tab, opts) do
      {:ok, Enum.uniq_by(links, &link_key/1)}
    end
  end

  @spec link_key(map()) :: term()
  defp link_key(link) when is_map(link) do
    case MapHelpers.get(link, :href) do
      href when is_binary(href) and href != "" -> {:href, href}
      _ -> link
    end
  end

  defp link_key(link), do: link
end
