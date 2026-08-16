defmodule Spectre.Lens.ActionProvider do
  @moduledoc """
  Late-bound Spectre action-provider adapter for the Lens browser boundary.

  It returns ordinary maps when Spectre is absent and native Action Specs when
  Spectre is loaded, keeping the Lens runtime dependency graph standalone.

  Planner visibility is opt-in through the installation option
  `planner_exposure: :all | [operation]`. Deterministic handlers may always
  address the provider as `via: :lens`.

  Every argument is plain JSON data, because Spectre validates Action arguments
  against a bounded JSON-Schema subset before dispatching them. A tab is the
  `SpectreLens.TabRef.to_map/1` projection returned by `:open`, a browser action
  is an object such as `%{"type" => "click", "text" => "Sign in"}`, and `opts`
  carries only the bounded keys below. The native `%SpectreLens.TabRef{}` and
  `{:click, ref}` forms remain the contract of the `SpectreLens` API itself.
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

  @export_atoms [:screenshot, :html, :markdown, :pdf]
  @export_types @export_atoms ++ Enum.map(@export_atoms, &Atom.to_string/1)

  @action_types ~w(navigate click fill submit scroll)

  # Argument keys are read through fixed allowlists so a model-supplied name
  # never reaches `String.to_atom/1` and never selects an option Lens does not
  # intend to expose. `network_policy`, `scorer` and the other runtime controls
  # stay out: they belong to the compiled installation, not to a planned Action.
  @action_string_keys [:ref, :href, :text, :name, :label, :title, :value, :form, :selector]
  @action_integer_keys [:x, :y]

  @opts_integer_keys [:timeout, :max_depth, :max_pages, :max_links_per_page, :max_candidates]

  @include_sections [
    :forms,
    :html,
    :interactive,
    :links,
    :llms,
    :markdown,
    :semantic_text,
    :semantic_tree,
    :structured_data
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
      case portable_tab(tab) do
        {:ok, map} ->
          {:ok, map}

        {:error, _reason} = error ->
          _ = SpectreLens.close_tab(tab)
          error
      end
    end
  end

  defp execute_operation(:look, args, runtime, config, opts) do
    case arg(args, :tab) do
      nil ->
        with {:ok, url} <- required(args, :url),
             {:ok, operation_opts} <- operation_opts(args, config, opts),
             {:ok, tab} <-
               SpectreLens.new_tab(runtime, Keyword.merge(policy_opts(config, opts), url: url)) do
          try do
            SpectreLens.look(tab, operation_opts)
          after
            SpectreLens.close_tab(tab)
          end
        end

      tab_ref ->
        with {:ok, %Tab{} = tab} <- resolve_tab(runtime, tab_ref),
             {:ok, operation_opts} <- operation_opts(args, config, opts) do
          SpectreLens.look(tab, operation_opts)
        end
    end
  end

  defp execute_operation(:discover, args, runtime, config, opts) do
    with {:ok, url} <- required(args, :url),
         {:ok, operation_opts} <- operation_opts(args, config, opts) do
      discover_opts =
        operation_opts
        |> Keyword.put(:url, url)
        |> maybe_put(:goal, arg(args, :goal))

      SpectreLens.discover(runtime, discover_opts)
    end
  end

  defp execute_operation(:act, args, runtime, config, opts) do
    with {:ok, tab_ref} <- required(args, :tab),
         {:ok, %Tab{} = tab} <- resolve_tab(runtime, tab_ref),
         {:ok, declared} <- required(args, :action),
         {:ok, action} <- normalize_action(declared),
         {:ok, operation_opts} <- operation_opts(args, config, opts) do
      tab
      |> SpectreLens.act(action, operation_opts)
      |> normalize_action_result()
    end
  end

  defp execute_operation(:export, args, runtime, config, opts) do
    with {:ok, tab_ref} <- required(args, :tab),
         {:ok, %Tab{} = tab} <- resolve_tab(runtime, tab_ref),
         {:ok, type} <- required(args, :type),
         {:ok, operation_opts} <- operation_opts(args, config, opts) do
      SpectreLens.export(tab, normalize_export_type(type), operation_opts)
    end
  end

  @spec portable_tab(Tab.t()) :: {:ok, map()} | {:error, term()}
  defp portable_tab(%Tab{} = tab) do
    with {:ok, %TabRef{} = ref} <- TabRef.new(tab), do: TabRef.to_map(ref)
  end

  # A browser action crosses the boundary as JSON and is rebuilt into the tuple
  # `SpectreLens.act/3` accepts. Native tuples still pass through for callers
  # that address this provider directly instead of through Spectre.
  @spec normalize_action(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_action(action) when is_tuple(action), do: {:ok, action}

  defp normalize_action(action) when is_map(action) and not is_struct(action) do
    with {:ok, type} <- action_type(action) do
      {:ok, build_action(type, action)}
    end
  end

  defp normalize_action(invalid), do: {:error, {:invalid_lens_action_request, invalid}}

  @spec action_type(map()) :: {:ok, atom()} | {:error, term()}
  defp action_type(action) do
    case value(action, :type) do
      type when is_atom(type) and not is_nil(type) ->
        if Atom.to_string(type) in @action_types,
          do: {:ok, type},
          else: {:error, {:unsupported_lens_action_type, type}}

      type when is_binary(type) ->
        if type in @action_types,
          do: {:ok, String.to_existing_atom(type)},
          else: {:error, {:unsupported_lens_action_type, type}}

      other ->
        {:error, {:unsupported_lens_action_type, other}}
    end
  end

  # `navigate` with an explicit URL addresses that URL; every other shape is a
  # query resolved against the live page by `SpectreLens.ActionResolver`.
  @spec build_action(atom(), map()) :: term()
  defp build_action(:navigate, action) do
    case value(action, :url) do
      url when is_binary(url) -> {:navigate, url}
      _absent -> {:navigate, action_keywords(action)}
    end
  end

  defp build_action(type, action), do: {type, action_keywords(action)}

  @spec action_keywords(map()) :: keyword()
  defp action_keywords(action) do
    strings = mapped_keywords(action, @action_string_keys, &is_binary/1)
    integers = mapped_keywords(action, @action_integer_keys, &is_integer/1)

    strings ++ integers ++ action_fields(action)
  end

  @spec action_fields(map()) :: keyword()
  defp action_fields(action) do
    case value(action, :fields) do
      fields when is_list(fields) ->
        [fields: Map.new(fields, &{value(&1, :name), value(&1, :value)})]

      fields when is_map(fields) and not is_struct(fields) ->
        [fields: fields]

      _absent ->
        []
    end
  end

  @spec mapped_keywords(map(), [atom()], (term() -> boolean())) :: keyword()
  defp mapped_keywords(source, keys, valid?) do
    Enum.flat_map(keys, fn key ->
      declared = value(source, key)
      if valid?.(declared), do: [{key, declared}], else: []
    end)
  end

  @spec authorize(map(), map(), map()) :: :ok | {:error, term()}
  defp authorize(%{policy: %{module: module, options: options}}, action, ctx) do
    operation = value(action, :name)
    args = value(action, :args) || %{}

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:lens_policy_unavailable, module}}

      function_exported?(module, :authorize, 3) ->
        module
        |> invoke(:authorize, operation, args, Keyword.put(options, :context, ctx))
        |> normalize_authorization(module, operation)

      true ->
        {:error, {:invalid_lens_policy, module, :authorize}}
    end
  end

  defp authorize(_config, _action, _ctx), do: :ok

  @spec normalize_authorization(term(), module(), atom()) :: :ok | {:error, term()}
  defp normalize_authorization(reply, _module, _operation) when reply in [:ok, true], do: :ok

  defp normalize_authorization(false, _module, operation),
    do: {:error, {:lens_policy_denied, operation}}

  defp normalize_authorization({:error, _reason} = error, _module, _operation), do: error

  defp normalize_authorization(other, module, _operation),
    do: {:error, {:invalid_lens_policy_reply, module, other}}

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

  # Installation and execution options are trusted and keep full keyword
  # freedom. Options carried by the Action itself are bounded to the allowlist,
  # so a planned Action cannot widen the network policy or swap a scorer.
  @spec operation_opts(map(), map(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp operation_opts(args, config, runtime_opts) do
    with {:ok, declared} <- declared_opts(arg(args, :opts)) do
      {:ok, Keyword.merge(policy_opts(config, runtime_opts), declared)}
    end
  end

  @spec declared_opts(term()) :: {:ok, keyword()} | {:error, term()}
  defp declared_opts(nil), do: {:ok, []}

  defp declared_opts(opts) when is_map(opts) and not is_struct(opts) do
    with {:ok, include} <- include_opt(value(opts, :include)) do
      {:ok, mapped_keywords(opts, @opts_integer_keys, &is_integer/1) ++ include}
    end
  end

  defp declared_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, {:invalid_lens_opts, opts}}
  end

  defp declared_opts(opts), do: {:error, {:invalid_lens_opts, opts}}

  @spec include_opt(term()) :: {:ok, keyword()} | {:error, term()}
  defp include_opt(nil), do: {:ok, []}

  defp include_opt(sections) when is_list(sections) do
    Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, acc} ->
      case include_section(section) do
        {:ok, section} -> {:cont, {:ok, [section | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sections} -> {:ok, [include: Enum.reverse(sections)]}
      {:error, _reason} = error -> error
    end
  end

  defp include_opt(sections), do: {:error, {:invalid_lens_include, sections}}

  @spec include_section(term()) :: {:ok, atom()} | {:error, term()}
  defp include_section(section) when section in @include_sections, do: {:ok, section}

  defp include_section(section) when is_binary(section) do
    case Enum.find(@include_sections, &(Atom.to_string(&1) == section)) do
      nil -> {:error, {:unsupported_lens_include, section}}
      section -> {:ok, section}
    end
  end

  defp include_section(section), do: {:error, {:unsupported_lens_include, section}}

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

  # Spectre validates these against its JSON-Schema subset before execution and
  # `mix spectre.doctor` additionally reports any planner-visible schema that
  # leaves a declared object open. Every property is therefore typed and every
  # object closed; nothing here relies on a value the subset cannot describe.
  @spec schema(atom()) :: map()
  defp schema(:open) do
    object(["url"], %{"url" => %{type: :string}, "opts" => opts_schema()})
  end

  defp schema(:discover) do
    object(["url"], %{
      "url" => %{type: :string},
      "goal" => %{type: :string},
      "opts" => opts_schema()
    })
  end

  defp schema(:look) do
    object([], %{
      "url" => %{type: :string},
      "tab" => tab_schema(),
      "opts" => opts_schema()
    })
  end

  defp schema(:act) do
    object(["tab", "action"], %{
      "tab" => tab_schema(),
      "action" => action_schema(),
      "opts" => opts_schema()
    })
  end

  defp schema(:export) do
    object(["tab", "type"], %{
      "tab" => tab_schema(),
      "type" => %{enum: @export_types},
      "opts" => opts_schema()
    })
  end

  @spec object([String.t()], map()) :: map()
  defp object(required, properties) do
    %{type: :object, additionalProperties: false, required: required, properties: properties}
  end

  @spec tab_schema() :: map()
  defp tab_schema do
    object(["id", "instance_id"], %{
      "version" => %{type: :integer},
      "id" => %{type: :string},
      "instance_id" => %{type: [:integer, :string]},
      "target_id" => %{type: :string, nullable: true},
      "session_id" => %{type: :string, nullable: true}
    })
  end

  @spec action_schema() :: map()
  defp action_schema do
    targets =
      Map.new(@action_string_keys, &{Atom.to_string(&1), %{type: :string}})
      |> Map.merge(Map.new(@action_integer_keys, &{Atom.to_string(&1), %{type: :integer}}))

    object(
      ["type"],
      Map.merge(targets, %{
        "type" => %{type: :string, enum: @action_types},
        "url" => %{type: :string},
        "fields" => %{
          type: :array,
          items:
            object(["name", "value"], %{
              "name" => %{type: :string},
              "value" => %{type: :string}
            })
        }
      })
    )
  end

  @spec opts_schema() :: map()
  defp opts_schema do
    object(
      [],
      Map.new(@opts_integer_keys, &{Atom.to_string(&1), %{type: :integer, minimum: 0}})
      |> Map.put("include", %{
        type: :array,
        items: %{type: :string, enum: Enum.map(@include_sections, &Atom.to_string/1)}
      })
    )
  end

  @spec build_spec(map()) :: map()
  defp build_spec(attrs) do
    if Code.ensure_loaded?(@spec_module) and function_exported?(@spec_module, :new, 1) do
      invoke(@spec_module, :new, attrs)
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

  defp resolve_tab(runtime, ref) when is_map(ref) do
    with {:ok, %TabRef{} = ref} <- TabRef.from_map(ref), do: resolve_tab(runtime, ref)
  end

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

  @spec normalize_export_type(term()) :: term()
  defp normalize_export_type(type) when type in @export_atoms, do: type

  defp normalize_export_type(type) when is_binary(type) do
    Enum.find(@export_atoms, type, &(Atom.to_string(&1) == type))
  end

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
        invoke(
          @journal_module,
          :record,
          agent,
          :lens_operation,
          %{operation: operation, outcome: outcome}
        )
    end

    :ok
  end

  @spec invoke(module(), atom(), term()) :: term()
  defp invoke(module, function, argument) do
    fun = Function.capture(module, function, 1)
    fun.(argument)
  end

  @spec invoke(module(), atom(), term(), term(), term()) :: term()
  defp invoke(module, function, argument1, argument2, argument3) do
    fun = Function.capture(module, function, 3)
    fun.(argument1, argument2, argument3)
  end

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
