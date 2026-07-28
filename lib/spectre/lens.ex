defmodule Spectre.Lens do
  @moduledoc """
  Stack-installable facade for the `SpectreLens` perception library.

  Lens owns its package-local `backend` and `policy` declarations:

      install Spectre.Lens do
        backend MyApp.BrowserBackend, instances: 2
        policy MyApp.WebPolicy
      end

  Version 0.1.2 compiles only immutable configuration. The package does not
  publish operations or start a browser runtime until those resources can be
  isolated and bound to a concrete Stack instance.
  """

  alias Spectre.Stack.DSL

  use Spectre.Stack.Installable,
    id: :lens,
    version: "0.1.2",
    contract: 1,
    spectre: "~> 0.1.2",
    provides: [{:service, :lens}],
    dsl: __MODULE__,
    metadata: %{role: :perception}

  @type component_config :: %{
          required(:module) => module(),
          required(:options) => keyword()
        }

  @type config :: %{
          required(:options) => keyword(),
          required(:backend) => component_config() | nil,
          required(:policy) => component_config() | nil
        }

  @doc false
  @impl Spectre.Stack.Installable
  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) :: {:ok, config()}
  def compile(opts, block, caller) do
    config =
      block
      |> DSL.compile!(caller, backend: [1, 2], policy: [1, 2])
      |> Enum.reduce(%{backend: nil, policy: nil}, &put_component!/2)
      |> Map.put(:options, opts)

    {:ok, config}
  end

  @spec put_component!({:backend | :policy, [term()]}, map()) :: map()
  defp put_component!({kind, arguments}, config) do
    case Map.fetch!(config, kind) do
      nil -> Map.put(config, kind, component_config!(kind, arguments))
      _configured -> raise ArgumentError, "Spectre.Lens #{kind} may only be declared once"
    end
  end

  @spec component_config!(:backend | :policy, [term()]) :: component_config()
  defp component_config!(kind, [module]), do: component_config!(kind, module, [])

  defp component_config!(kind, [module, options]),
    do: component_config!(kind, module, options)

  @spec component_config!(:backend | :policy, term(), term()) :: component_config()
  defp component_config!(kind, module, options)
       when is_atom(module) and not is_nil(module) and is_list(options) do
    if Keyword.keyword?(options) do
      %{module: module, options: options}
    else
      raise ArgumentError,
            "Spectre.Lens #{kind} options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp component_config!(kind, module, options) do
    raise ArgumentError,
          "Spectre.Lens #{kind} must be a module with keyword options, got: " <>
            "#{inspect(module)}, #{inspect(options)}"
  end
end
