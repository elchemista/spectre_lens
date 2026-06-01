defmodule SpectreLens.Plugs.StructuredData do
  @moduledoc """
  Adds structured page metadata when `:structured_data` is requested.

  The browser adapter owns the extraction format; the plug records either the
  metadata or a tagged projection error on the context.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
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
