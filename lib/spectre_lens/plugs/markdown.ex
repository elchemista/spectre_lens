defmodule SpectreLens.Plugs.Markdown do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :markdown) do
      Helpers.collect(context, :markdown, fn ->
        SpectreLens.Protocol.markdown(context.tab, opts)
      end)
    else
      context
    end
  end
end
