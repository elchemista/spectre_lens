defmodule Spectre.Lens.ActionProvider do
  @moduledoc """
  Late-bound Spectre action-provider adapter for the Lens browser boundary.

  It returns ordinary maps when Spectre is absent and native Action Specs when
  Spectre is loaded, keeping the Lens runtime dependency graph standalone.

  Planner visibility is opt-in through the installation option
  `planner_exposure: :all | [operation]`. Deterministic handlers may always
  address the provider as `via: :lens`.
  """

  alias SpectreLens.Tab
  alias SpectreLens.TabRef

  @journal_module Module.concat(["Spectre", "Journal"])
  @spec_module Module.concat(["Spectre", "Action", "Spec"])

  @operations [
    {:open, :read, "Open a browser tab for a URL"},
    {:look, :read, "Return an agent-readable view of a URL or tab"},
    {:discover, :read, "Discover a goal-scoped navigation frontier"},
    {:act, :write, "Perform an explicit browser action on a tab"},
    {:export, :read, "Export a page artifact from a tab"}
  ]

  @spec actions(keyword()) :: [map()]
  def actions(opts) do
    config = Keyword.fetch!(opts, :config)

    Enum.map(@operations, fn {name, mode, description} ->
      build_spec(%{
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

  @spec execute(map(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(action, ctx, opts) when is_map(action) and is_map(ctx) do
    config = Keyword.fetch!(opts, :config)
    operation = value(action, :name)
    args = value(action, :args) || %{}
    agent = value(ctx, :agent)
    context_opts = value(ctx, :opts) || []

    with :ok <- matching_provider(action),
         :ok <- known_operation(operation),
         :ok <- authorize(config, action, ctx),
         {:ok, runtime} <- Spectre.Lens.runtime(agent, context_opts),
         result <- execute_operation(operation, args, runtime, config, context_opts) do
      record(agent, operation, result)
      result
    end
  end

  def execute(action, _ctx, _opts),
    do: {:error, {:invalid_lens_action, action}}

  @spec schema_hash(map(), keyword()) :: String.t() | nil
  def schema_hash(action, opts) when is_map(action) do
    actions(opts)
    |> Enum.find(
      &(value(&1, :name) == value(action, :name) and
          value(&1, :via) == value(action, :via))
    )
    |> case do
      nil -> nil
      spec -> value(spec, :schema_hash)
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

  @spec authorize(map(), map(), map()) :: :ok | {:error, term()}
  defp authorize(%{policy: %{module: module, options: options}}, action, ctx) do
    operation = value(action, :name)
    args = value(action, :args) || %{}

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:lens_policy_unavailable, module}}

      function_exported?(module, :authorize, 3) ->
        case apply(module, :authorize, [operation, args, Keyword.put(options, :context, ctx)]) do
          :ok -> :ok
          true -> :ok
          false -> {:error, {:lens_policy_denied, operation}}
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

  @spec build_spec(map()) :: map()
  defp build_spec(attrs) do
    if Code.ensure_loaded?(@spec_module) and function_exported?(@spec_module, :new, 1) do
      apply(@spec_module, :new, [attrs])
    else
      Map.put(attrs, :schema_hash, fallback_schema_hash(attrs))
    end
  end

  @spec fallback_schema_hash(map()) :: String.t()
  defp fallback_schema_hash(attrs) do
    :sha256
    |> :crypto.hash(
      :erlang.term_to_binary(
        {Map.fetch!(attrs, :via), Map.fetch!(attrs, :name), Map.get(attrs, :mode),
         Map.get(attrs, :schema, %{})},
        [:deterministic]
      )
    )
    |> Base.encode16(case: :lower)
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

  @spec matching_provider(map()) :: :ok | {:error, term()}
  defp matching_provider(action) do
    case value(action, :via) do
      :lens -> :ok
      other -> {:error, {:lens_action_provider_mismatch, other}}
    end
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
    value(args, key)
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

    if Code.ensure_loaded?(@journal_module) and
         function_exported?(@journal_module, :record, 3) do
      _journal =
        apply(@journal_module, :record, [
          agent,
          :lens_operation,
          %{operation: operation, outcome: outcome}
        ])
    end

    :ok
  end

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
