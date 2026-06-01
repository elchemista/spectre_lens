defmodule SpectreLens.PlugPipeline do
  @moduledoc """
  Runs the `SpectreLens.look/2` projection pipeline.

  The pipeline accepts built-in plugs, application-configured plugs, and
  per-call plugs. Each plug receives the same `%SpectreLens.Context{}` and can
  continue, halt with the current context, or return a tagged error.

  ## Examples

      SpectreLens.PlugPipeline.run(%SpectreLens.Context{}, plugs: [])
  """

  alias SpectreLens.Context

  @type plug :: module() | {module(), keyword()}
  @type run_result :: {:ok, Context.t()} | {:error, term()}
  @typep plug_result :: {:cont, Context.t()} | {:halt, Context.t()} | {:error, term()}

  @doc "Runs configured plugs and returns the final context or a tagged error."
  @spec run(Context.t(), keyword()) :: run_result()
  def run(%Context{} = context, opts \\ []) do
    opts
    |> plugs()
    |> Enum.reduce_while({:ok, context}, fn plug, {:ok, acc} ->
      case call_plug(plug, acc, opts) do
        {:cont, %Context{} = next} -> {:cont, {:ok, next}}
        {:halt, %Context{} = next} -> {:halt, {:ok, %{next | halted?: true}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec plugs(keyword()) :: [plug()]
  defp plugs(opts) do
    builtin? = Keyword.get(opts, :builtin_plugs?, true)
    builtins = if builtin?, do: SpectreLens.Plugs.default(), else: []
    configured = Application.get_env(:spectre_lens, :plugs, [])
    local = Keyword.get(opts, :plugs, [])
    builtins ++ List.wrap(configured) ++ List.wrap(local)
  end

  @spec call_plug(plug(), Context.t(), keyword()) :: plug_result()
  defp call_plug({module, plug_opts}, context, opts) when is_atom(module) do
    call_plug(module, context, Keyword.merge(opts, plug_opts))
  end

  defp call_plug(module, context, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      module.call(context, opts) |> normalize_result()
    else
      {:error, {:plug_not_available, module}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_plug(other, _context, _opts), do: {:error, {:invalid_plug, other}}

  @spec normalize_result(term()) :: plug_result()
  defp normalize_result(%Context{} = context), do: {:cont, context}
  defp normalize_result({:cont, %Context{} = context}), do: {:cont, context}
  defp normalize_result({:halt, %Context{} = context}), do: {:halt, context}
  defp normalize_result({:ok, %Context{} = context}), do: {:cont, context}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, {:invalid_plug_result, other}}
end
