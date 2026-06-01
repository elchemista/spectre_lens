defmodule SpectreLens.Plugs.Forms do
  @moduledoc """
  Adds form metadata to a view when `:forms` is requested.

  Form extraction stays in the browser adapter; this plug only decides whether
  the projection belongs in the current look pipeline.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :forms) do
      Helpers.collect(context, :forms, fn -> SpectreLens.Protocol.forms(context.tab, opts) end)
    else
      context
    end
  end
end
