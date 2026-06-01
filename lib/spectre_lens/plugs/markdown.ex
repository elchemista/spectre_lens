defmodule SpectreLens.Plugs.Markdown do
  @moduledoc """
  Adds Lightpanda's Markdown projection when `:markdown` is requested.

  Markdown is the default compact representation used by `SpectreLens.look/2`.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
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
