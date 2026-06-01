defmodule SpectreLens.Plugs.Helpers do
  @moduledoc """
  Shared helpers for `SpectreLens.look/2` pipeline plugs.

  These helpers keep projection plugs consistent: missing optional data is
  recorded on the view instead of raising, and requested keys are checked in one
  place.
  """

  alias SpectreLens.Context

  @doc "Returns true when a projection key was requested for the current view."
  @spec included?(Context.t(), atom()) :: boolean()
  def included?(%Context{include: include}, key), do: key in include

  @doc "Appends an error to the view while preserving pipeline flow."
  @spec put_error(Context.t(), term()) :: Context.t()
  def put_error(%Context{} = context, reason) do
    update_in(context.view.errors, &[reason | &1])
  end

  @doc "Appends a warning to the view while preserving pipeline flow."
  @spec put_warning(Context.t(), term()) :: Context.t()
  def put_warning(%Context{} = context, reason) do
    update_in(context.view.warnings, &[reason | &1])
  end

  @doc "Runs a projection fetcher and stores either its value or tagged error."
  @spec collect(Context.t(), atom(), (-> {:ok, term()} | {:error, term()})) :: Context.t()
  def collect(%Context{} = context, key, fun) do
    case fun.() do
      {:ok, value} -> %{context | view: Map.put(context.view, key, value)}
      {:error, reason} -> put_error(context, {key, reason})
    end
  end
end
