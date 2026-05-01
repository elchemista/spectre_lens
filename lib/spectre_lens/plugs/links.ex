defmodule SpectreLens.Plugs.Links do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :links) do
      Helpers.collect(context, :links, fn -> SpectreLens.Protocol.links(context.tab, opts) end)
    else
      context
    end
  end
end
