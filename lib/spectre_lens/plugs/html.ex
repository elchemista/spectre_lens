defmodule SpectreLens.Plugs.Html do
  @moduledoc """
  Adds rendered HTML when callers explicitly request `:html`.

  HTML is intentionally opt-in because it can be large compared with Markdown
  and semantic projections.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :html) do
      Helpers.collect(context, :html, fn -> SpectreLens.Protocol.html(context.tab, opts) end)
    else
      context
    end
  end
end
