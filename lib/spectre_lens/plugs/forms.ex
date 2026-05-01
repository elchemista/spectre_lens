defmodule SpectreLens.Plugs.Forms do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :forms) do
      Helpers.collect(context, :forms, fn -> SpectreLens.Protocol.forms(context.tab, opts) end)
    else
      context
    end
  end
end
