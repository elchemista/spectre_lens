defmodule SpectreLens.Plugs.Html do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :html) do
      Helpers.collect(context, :html, fn -> SpectreLens.Protocol.html(context.tab, opts) end)
    else
      context
    end
  end
end
