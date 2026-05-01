defmodule SpectreLens.Plugs.BasicInfo do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, _opts) do
    context
    |> Helpers.collect(:url, fn -> SpectreLens.Protocol.url(context.tab) end)
    |> Helpers.collect(:title, fn -> SpectreLens.Protocol.title(context.tab) end)
  end
end
