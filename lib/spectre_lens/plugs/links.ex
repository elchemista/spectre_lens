defmodule SpectreLens.Plugs.Links do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :links) do
      Helpers.collect(context, :links, fn ->
        with {:ok, links} <- SpectreLens.Protocol.links(context.tab, opts) do
          {:ok, Enum.uniq_by(links, &link_key/1)}
        end
      end)
    else
      context
    end
  end

  @spec link_key(map()) :: term()
  defp link_key(%{"href" => href}) when is_binary(href), do: href
  defp link_key(%{href: href}) when is_binary(href), do: href
  defp link_key(link), do: link
end
