defmodule SpectreLens.Plug do
  @moduledoc "Behaviour for Spectre Lens look/inspection pipeline plugs."

  @type result ::
          SpectreLens.Context.t()
          | {:cont, SpectreLens.Context.t()}
          | {:halt, SpectreLens.Context.t()}
          | {:error, term()}

  @doc "Transforms or halts a `SpectreLens.Context` during `SpectreLens.look/2`."
  @callback call(SpectreLens.Context.t(), keyword()) :: result()
end
