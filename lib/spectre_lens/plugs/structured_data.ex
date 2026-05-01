defmodule SpectreLens.Plugs.StructuredData do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :structured_data) do
      Helpers.collect(context, :structured_data, fn ->
        SpectreLens.Protocol.structured_data(context.tab, opts)
      end)
    else
      context
    end
  end
end
