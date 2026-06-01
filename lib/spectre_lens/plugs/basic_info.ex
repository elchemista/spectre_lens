defmodule SpectreLens.Plugs.BasicInfo do
  @moduledoc """
  Collects the page URL and title for every `SpectreLens.look/2` view.

  This plug runs before optional projections so later plugs can use the current
  URL for diagnostics, `llms.txt` discovery, and agent context.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, _opts) do
    context
    |> Helpers.collect(:url, fn -> SpectreLens.Protocol.url(context.tab) end)
    |> Helpers.collect(:title, fn -> SpectreLens.Protocol.title(context.tab) end)
  end
end
