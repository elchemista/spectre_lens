defmodule Spectre.Lens.ActionProvider do
  @moduledoc """
  Spectre action-provider adapter for the Lens browser boundary.

  Planner visibility is opt-in through the installation option
  `planner_exposure: :all | [operation]`. Deterministic handlers may always
  address the provider as `via: :lens`.
  """

  @behaviour Spectre.Action.Provider

  alias Spectre.Action
  alias Spectre.Action.Spec
  alias SpectreLens.Tab
  alias SpectreLens.TabRef

  @operations [
    {:open, :read, "Open a browser tab for a URL"},
    {:look, :read, "Return an agent-readable view of a URL or tab"},
    {:discover, :read, "Discover a goal-scoped navigation frontier"},
    {:act, :write, "Perform an explicit browser action on a tab"},
    {:export, :read, "Export a page artifact from a tab"}
  ]

  @impl true
  def actions(opts) do
    config = Keyword.fetch!(opts, :config)

    Enum.map(@operations, fn {name, mode, description} ->
      Spec.new(%{
        id: "lens.#{name}",
        name: name,
        via: :lens,
        description: description,
        mode: mode,
        visibility: visibility(config, name),
        schema: schema(name),
        metadata: %{service: :lens}
      })
    end)
  end

  @impl true
  def execute(%Action{via: :lens} = action, ctx, opts) do
    config = Keyword.fetch!(opts, :config)

    with :ok <- known_operation(action.name),
         :ok <- authorize(config, action, ctx),
         {:ok, runtime} <- Spectre.Lens.runtime(ctx.agent, ctx.opts),
         result <- execute_operation(action.name, action.args, runtime, config, ctx.opts) do
      record(ctx.agent, action.name, result)
      result
    end
  end

  def execute(%Action{} = action, _ctx, _opts),
    do: {:error, {:lens_action_provider_mismatch, action.via}}

  @impl true
  def schema_hash(%Action{} = action, opts) do
    case Enum.find(actions(opts), &(&1.name == action.name and &1.via == action.via)) do
      %Spec{schema_hash: hash} -> hash
      nil -> nil
    end
  end

  @spec execute_operation(atom(), map(), term(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp execute_operation(:open, args, runtime, config, opts) do
    with {:ok, url} <- required(args, :url),
         {:ok, %Tab{} = tab} <-
           SpectreLens.new_tab(runtime, Keyword.merge(policy_opts(config, opts), url: url)) do
      case TabRef.new(tab) do
        {:ok, %TabRef{} = ref} ->
          {:ok, ref}

        {:error, _reason} = error ->
          _ = SpectreLens.close_tab(tab)
          error
      end
    end
  end

  defp execute_operation(:look, args, runtime, config, opts) do
    case arg(args, :tab) do
      %TabRef{} = ref ->
        with {:ok, tab} <- SpectreLens.resolve_tab(runtime, ref) do
          SpectreLens.look(tab, operation_opts(args, config, opts))
        end

      %Tab{} ->
        {:error, :nonportable_lens_tab}

      nil ->
        with {:ok, url} <- required(args, :url),
             {:ok, tab} <-
               SpectreLens.new_tab(runtime, Keyword.merge(policy_opts(config, opts), url: url)) do
          try do
            SpectreLens.look(tab, operation_opts(args, config, opts))
          after
            SpectreLens.close_tab(tab)
          end
        end

      invalid ->
        {:error, {:invalid_lens_tab, invalid}}
    end
  end

  defp execute_operation(:discover, args, runtime, config, opts) do
    with {:ok, url} <- required(args, :url) do
      discover_opts =
        args
        |> operation_opts(config, opts)
        |> Keyword.put(:url, url)
        |> maybe_put(:goal, arg(args, :goal))

      SpectreLens.discover(runtime, discover_opts)
    end
  end

  defp execute_operation(:act, args, runtime, config, opts) do
    with {:ok, tab_ref} <- required(args, :tab),
         {:ok, %Tab{} = tab} <- resolve_tab(runtime, tab_ref),
         {:ok, action} <- required(args, :action) do
      tab
      |> SpectreLens.act(action, operation_opts(args, config, opts))
      |> normalize_action_result()
    end
  end

  defp execute_operation(:export, args, runtime, config, opts) do
    with {:ok, tab_ref} <- required(args, :tab),
         {:ok, %Tab{} = tab} <- resolve_tab(runtime, tab_ref),
         {:ok, type} <- required(args, :type) do
      SpectreLens.export(tab, normalize_export_type(type), operation_opts(args, config, opts))
    end
  end

  @spec authorize(map(), Action.t(), Spectre.Context.t()) :: :ok | {:error, term()}
  defp authorize(%{policy: %{module: module, options: options}}, action, ctx) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:lens_policy_unavailable, module}}

      function_exported?(module, :authorize, 3) ->
        case module.authorize(action.name, action.args, Keyword.put(options, :context, ctx)) do
          :ok -> :ok
          true -> :ok
          false -> {:error, {:lens_policy_denied, action.name}}
          {:error, _reason} = error -> error
          other -> {:error, {:invalid_lens_policy_reply, module, other}}
        end

      true ->
        {:error, {:invalid_lens_policy, module, :authorize}}
    end
  end

  defp authorize(_config, _action, _ctx), do: :ok

  @spec policy_opts(map(), keyword()) :: keyword()
  defp policy_opts(config, runtime_opts) do
    declared =
      case Map.get(config, :policy) do
        %{options: options} -> options
        _other -> []
      end

    declared
    |> Keyword.merge(Keyword.get(runtime_opts, :lens_opts, []))
  end

  @spec operation_opts(map(), map(), keyword()) :: keyword()
  defp operation_opts(args, config, runtime_opts) do
    policy_opts(config, runtime_opts)
    |> Keyword.merge(keyword_arg(args, :opts))
  end

  @spec visibility(map(), atom()) :: :deterministic | :both
  defp visibility(config, operation) do
    case config |> Map.get(:options, []) |> Keyword.get(:planner_exposure, []) do
      :all ->
        :both

      operations when is_list(operations) ->
        if operation in operations, do: :both, else: :deterministic

      _other ->
        :deterministic
    end
  end

  @spec schema(atom()) :: map()
  defp schema(operation) when operation in [:open, :discover] do
    %{
      type: :object,
      required: [:url],
      properties: %{
        url: %{type: :string},
        goal: %{type: :string}
      }
    }
  end

  defp schema(:look) do
    %{
      type: :object,
      required: [],
      properties: %{
        url: %{type: :string},
        tab: %{type: :object}
      }
    }
  end

  defp schema(:act) do
    %{type: :object, required: [:tab, :action], properties: %{tab: %{}, action: %{}}}
  end

  defp schema(:export) do
    %{
      type: :object,
      required: [:tab, :type],
      properties: %{tab: %{}, type: %{type: :string}}
    }
  end

  @spec resolve_tab(term(), term()) :: {:ok, Tab.t()} | {:error, term()}
  defp resolve_tab(runtime, %TabRef{} = ref), do: SpectreLens.resolve_tab(runtime, ref)
  defp resolve_tab(_runtime, %Tab{}), do: {:error, :nonportable_lens_tab}
  defp resolve_tab(_runtime, invalid), do: {:error, {:invalid_lens_tab_ref, invalid}}

  @spec known_operation(atom()) :: :ok | {:error, term()}
  defp known_operation(name) do
    if Enum.any?(@operations, &(elem(&1, 0) == name)),
      do: :ok,
      else: {:error, {:unsupported_lens_operation, name}}
  end

  @spec required(map(), atom()) :: {:ok, term()} | {:error, term()}
  defp required(args, key) do
    case arg(args, key) do
      nil -> {:error, {:missing_lens_argument, key}}
      value -> {:ok, value}
    end
  end

  @spec arg(map(), atom()) :: term()
  defp arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      {:ok, value} -> value
      :error -> Map.get(args, Atom.to_string(key))
    end
  end

  @spec keyword_arg(map(), atom()) :: keyword()
  defp keyword_arg(args, key) do
    case arg(args, key) do
      opts when is_list(opts) -> if Keyword.keyword?(opts), do: opts, else: []
      _other -> []
    end
  end

  @spec normalize_export_type(term()) :: term()
  defp normalize_export_type(type) when type in [:screenshot, :html, :markdown, :pdf], do: type
  defp normalize_export_type("screenshot"), do: :screenshot
  defp normalize_export_type("html"), do: :html
  defp normalize_export_type("markdown"), do: :markdown
  defp normalize_export_type("pdf"), do: :pdf
  defp normalize_export_type(type), do: type

  @spec normalize_action_result(:ok | {:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  defp normalize_action_result(:ok), do: {:ok, :ok}
  defp normalize_action_result({:ok, _result} = result), do: result
  defp normalize_action_result({:error, _reason} = error), do: error

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec record(module(), atom(), term()) :: :ok
  defp record(agent, operation, result) do
    outcome =
      case result do
        {:ok, _value} -> :ok
        {:error, _reason} -> :error
      end

    _journal =
      Spectre.Journal.record(agent, :lens_operation, %{operation: operation, outcome: outcome})

    :ok
  end
end
