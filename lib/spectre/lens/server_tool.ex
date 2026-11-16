defmodule Spectre.Lens.ServerTool do
  @moduledoc """
  Spectre 0.4 tool boundary for supervised Lens browser resources.

  Bound browser interactions through `:act`, `:open` and `:look` are governed.
  Navigation bindings require both open and look. Opening a tab is non-repeatable after an
  uncertain result; look is repeatable. Close explicitly releases a known tab.
  Hosts must also configure browser leases/cleanup for abandoned or uncertain
  opens. No live Tab or connection handle crosses the Server checkpoint.
  """

  alias Spectre.Lens.ActionProvider
  alias SpectreLens.{TabRef, View}

  @schema Module.concat(["Spectre", "Action", "Schema"])

  if Code.ensure_loaded?(Spectre.Server.GAM.EffectAdapter) do
    @behaviour Spectre.Server.GAM.EffectAdapter
  end

  @doc "Runs a registered browser action after admission, without retry."
  @spec execute_effect(:act | :open | :look, map(), map()) ::
          {:ok, term()} | {:error, :definitive_no_effect | :ambiguous, term()}
  def execute_effect(operation, args, context) when operation in [:act, :open, :look] do
    with {:ok, config} <- Spectre.Lens.config(context.agent),
         {:ok, _} <- validate(operation, args, config) do
      case execute(operation, args, context) do
        {:ok, receipt} -> {:ok, receipt}
        {:error, reason} -> {:error, :ambiguous, reason}
      end
    else
      {:error, reason} -> {:error, :definitive_no_effect, reason}
    end
  end

  def execute_effect(_, _, _), do: {:error, :definitive_no_effect, :invalid_lens_effect}

  def prepare(:open, [url], trusted) when is_binary(url),
    do: validate(:open, %{"url" => url}, trusted.config)

  def prepare(:look, [url], trusted) when is_binary(url),
    do: validate(:look, %{"url" => url}, trusted.config)

  def prepare(:look, [tab], trusted) do
    with {:ok, tab} <- tab_map(tab),
         do: validate(:look, %{"tab" => tab}, trusted.config)
  end

  def prepare(:close, [tab], _trusted) do
    with {:ok, tab} <- tab_map(tab), do: {:ok, %{"tab" => tab}}
  end

  def prepare(:act, [tab, action], trusted) when is_map(action) and not is_struct(action) do
    with {:ok, tab} <- tab_map(tab),
         do: validate(:act, %{"tab" => tab, "action" => action}, trusted.config)
  end

  def prepare(_operation, _payload, _trusted), do: {:error, :invalid_lens_request}

  def invoke(operation, args, %{service_context: context, config: config})
      when operation in [:open, :look],
      do: invoke_provider(operation, args, context, config)

  def invoke(:close, %{"tab" => tab}, %{service_context: context}) do
    with {:ok, runtime} <- Spectre.Lens.runtime(context.agent, context.options),
         {:ok, ref} <- TabRef.from_map(tab),
         {:ok, live_tab} <- SpectreLens.resolve_tab(runtime, ref),
         :ok <- SpectreLens.close_tab(live_tab) do
      {:ok, %{closed: true}}
    end
  end

  @doc "Called only inside an admitted host GAM executor; projects before Outcome attestation."
  def execute(operation, args, context) when operation in [:act, :open, :look] do
    with {:ok, config} <- Spectre.Lens.config(context.agent),
         {:ok, args} <- validate(operation, args, config),
         raw <- invoke_provider(operation, args, context, config),
         {:ok, projected} <- project(operation, raw) do
      projected
    end
  end

  def project(:look, {:ok, %View{} = view}) do
    with {:ok, content} <- SpectreLens.agent_context(view) do
      projected =
        view
        |> Map.take([:url, :title, :markdown, :semantic_text, :links, :forms, :actions])
        |> Map.merge(%{trust: :untrusted, context: content})
        |> portable()

      {:ok, {:ok, projected}}
    end
  rescue
    ArgumentError -> {:error, :nonportable_lens_result}
  end

  def project(_operation, {:ok, value}) do
    {:ok, {:ok, portable(value)}}
  rescue
    ArgumentError -> {:error, :nonportable_lens_result}
  end

  def project(_operation, {:error, reason}), do: {:ok, {:error, reason}}
  def project(_operation, :ok), do: {:ok, :ok}
  def project(_operation, _result), do: {:error, :invalid_lens_result}

  defp invoke_provider(operation, args, context, config) do
    ActionProvider.execute(
      %{name: operation, via: :lens, args: args},
      %{agent: context.agent, opts: context.options},
      config: config
    )
  end

  defp validate(operation, args, config) do
    spec = Enum.find(ActionProvider.actions(config: config), &(&1.name == operation))

    case apply(@schema, :validate, [spec.schema, args]) do
      :ok -> {:ok, args}
      {:error, reason} -> {:error, {:invalid_lens_arguments, reason}}
    end
  end

  defp tab_map(%TabRef{} = ref), do: TabRef.to_map(ref)

  defp tab_map(map) when is_map(map) and not is_struct(map) do
    with {:ok, ref} <- TabRef.from_map(map), do: TabRef.to_map(ref)
  end

  defp tab_map(_), do: {:error, :lens_tab_reference_required}

  defp portable(%SpectreLens.ActionRef{} = ref), do: ref |> Map.from_struct() |> portable()
  defp portable(%_{}), do: raise(ArgumentError, "unsupported browser record")

  defp portable(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {portable(key), portable(item)} end)

  defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)

  defp portable(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&portable/1) |> List.to_tuple()

  defp portable(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp portable(_), do: raise(ArgumentError, "nonportable browser value")
end
