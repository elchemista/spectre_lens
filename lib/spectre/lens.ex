defmodule Spectre.Lens do
  @moduledoc """
  Optional, late-bound Spectre Stack facade for the standalone `SpectreLens`
  perception library.

  Lens owns its package-local `backend` and `policy` declarations:

      install Spectre.Lens do
        backend MyApp.BrowserBackend, instances: 2
        policy MyApp.WebPolicy
      end

  This module compiles without Spectre. When Spectre is present, configuration
  stays immutable and browser processes are isolated under an explicitly
  started `Spectre.Stack.Runtime`; Agents receive the provider binding without
  owning a second compiler.
  """

  @version "0.2.0"
  @spectre_definition Module.concat(["Spectre", "Definition"])
  @spectre_extension Module.concat(["Spectre", "Extension"])
  @spectre_stack Module.concat(["Spectre", "Stack"])
  @spectre_stack_dsl Module.concat(["Spectre", "Stack", "DSL"])
  @spectre_stack_runtime Module.concat(["Spectre", "Stack", "Runtime"])

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
  @spec manifest() :: keyword()
  def manifest do
    [
      id: :lens,
      module: __MODULE__,
      version: @version,
      contract: 1,
      spectre: "~> 0.2.0",
      provides: [{:service, :lens}],
      actions: [
        {:lens, :open},
        {:lens, :look},
        {:lens, :discover},
        {:lens, :act},
        {:lens, :export}
      ],
      resources: [{:lens, :runtime}],
      agent_extensions: [Spectre.Lens.Extension],
      dsl: __MODULE__,
      metadata: %{role: :perception}
    ]
  end

  @doc false
  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) :: {:ok, config()}
  def compile(opts, block, caller) do
    with :ok <- ensure_exported(@spectre_stack_dsl, :compile!, 3) do
      config =
        invoke(@spectre_stack_dsl, :compile!, block, caller,
          backend: [1, 2],
          policy: [1, 2]
        )
        |> Enum.reduce(%{backend: nil, policy: nil}, &put_component!/2)
        |> Map.put(:options, opts)

      {:ok, config}
    end
  end

  def child_specs(installation, runtime_opts) do
    config = installation.config

    backend_opts =
      case config.backend do
        %{module: module, options: options} -> Keyword.put(options, :backend, module)
        nil -> []
      end

    opts =
      backend_opts
      |> Keyword.merge(config.options)
      |> Keyword.merge(runtime_opts)

    child_spec =
      Supervisor.child_spec(
        {SpectreLens.Runtime, opts},
        id: {:spectre_lens_runtime, installation.id}
      )

    [{{:lens, :runtime}, child_spec}]
  end

  defmacro __using__(opts) do
    quote do
      register = Function.capture(unquote(@spectre_extension), :register!, 3)
      register.(__MODULE__, Spectre.Lens.Extension, unquote(opts))
    end
  end

  @doc """
  Returns the immutable Lens installation bound to an Agent.
  """
  @spec config(module()) :: {:ok, config()} | {:error, term()}
  def config(agent) when is_atom(agent) do
    with :ok <- ensure_exported(@spectre_extension, :fetch, 2),
         {:ok, mount} <- invoke(@spectre_extension, :fetch, agent, :lens),
         config when is_map(config) <- Map.get(mount, :compiled) do
      {:ok, config}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_lens_configuration}
    end
  end

  @doc """
  Resolves the caller-owned Lens runtime from execution options.

  Pass `lens_runtime:` directly, or pass the running `Spectre.Stack.Runtime`
  supervisor as `stack_runtime:`.
  """
  @spec runtime(module(), keyword()) :: {:ok, pid() | SpectreLens.Runtime.t()} | {:error, term()}
  def runtime(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    case Keyword.get(opts, :lens_runtime) do
      %SpectreLens.Runtime{} = runtime ->
        {:ok, runtime}

      runtime when is_pid(runtime) ->
        {:ok, runtime}

      nil ->
        resolve_stack_runtime(agent, Keyword.get(opts, :stack_runtime))

      invalid ->
        {:error, {:invalid_lens_runtime, invalid}}
    end
  end

  @spec resolve_stack_runtime(module(), term()) :: {:ok, pid()} | {:error, term()}
  defp resolve_stack_runtime(_agent, nil), do: {:error, :lens_runtime_required}

  defp resolve_stack_runtime(agent, supervisor) do
    with :ok <- ensure_exported(@spectre_definition, :fetch!, 1),
         :ok <- ensure_exported(@spectre_stack, :resolve, 3),
         :ok <- ensure_exported(@spectre_stack_runtime, :resolve, 2),
         %{stack: stack} when is_atom(stack) and not is_nil(stack) <-
           invoke(@spectre_definition, :fetch!, agent),
         {:ok, ref} <- invoke(@spectre_stack, :resolve, stack, :resource, {:lens, :runtime}),
         {:ok, pid} <- invoke(@spectre_stack_runtime, :resolve, supervisor, ref) do
      {:ok, pid}
    else
      %{stack: nil} -> {:error, :lens_stack_required}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_lens_stack_binding}
    end
  end

  @spec ensure_exported(module(), atom(), non_neg_integer()) ::
          :ok | {:error, :spectre_not_available}
  defp ensure_exported(module, function, arity) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: :ok,
      else: {:error, :spectre_not_available}
  end

  @spec invoke(module(), atom(), term()) :: term()
  defp invoke(module, function, argument) do
    fun = Function.capture(module, function, 1)
    fun.(argument)
  end

  @spec invoke(module(), atom(), term(), term()) :: term()
  defp invoke(module, function, argument1, argument2) do
    fun = Function.capture(module, function, 2)
    fun.(argument1, argument2)
  end

  @spec invoke(module(), atom(), term(), term(), term()) :: term()
  defp invoke(module, function, argument1, argument2, argument3) do
    fun = Function.capture(module, function, 3)
    fun.(argument1, argument2, argument3)
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
