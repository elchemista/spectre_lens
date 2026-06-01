defmodule SpectreLens do
  @moduledoc """
  Agent-first browser lens for Lightpanda.

  Spectre Lens controls Lightpanda through CDP and returns compact page views
  designed for agents: markdown, semantic structure, interactive elements,
  forms, links, structured data and action references.
  """

  alias SpectreLens.{
    ActionResolver,
    Context,
    Discovery,
    LlmsTxt,
    Outline,
    PlugPipeline,
    Region,
    Runtime,
    Session,
    Tab,
    View,
    Watcher
  }

  @default_include [:markdown, :interactive, :forms, :links]

  @doc """
  Starts a Spectre Lens runtime.

  The default Lightpanda driver supports one live tab per instance. Use
  `instances: n` when you need up to `n` concurrent Lightpanda tabs.
  """
  @spec open(keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  def open(opts \\ []) do
    SpectreLens.Errors.safe(:open, fn ->
      with {:ok, pid} <- Runtime.start_link(opts) do
        {:ok, %Runtime{pid: pid}}
      end
    end)
  end

  @doc "Creates a new tab in a runtime."
  @spec new_tab(Runtime.t() | pid(), keyword()) :: {:ok, Tab.t()} | {:error, term()}
  def new_tab(runtime, opts \\ []) do
    SpectreLens.Errors.safe(:new_tab, fn -> Runtime.new_tab(runtime, opts) end)
  end

  @doc "Closes a tab and releases its runtime capacity."
  @spec close_tab(Tab.t()) :: :ok | {:error, term()}
  def close_tab(%Tab{} = tab) do
    SpectreLens.Errors.safe(:close_tab, fn -> SpectreLens.Protocol.close_tab(tab) end)
  end

  @doc "Captures a tab's browser session into the runtime ETS session store."
  @spec save_session(Tab.t(), term() | keyword() | nil, keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def save_session(tab, key \\ nil, opts \\ [])

  def save_session(%Tab{} = tab, opts, []) when is_list(opts) do
    SpectreLens.Errors.safe(:save_session, fn -> Runtime.save_session(tab, nil, opts) end)
  end

  def save_session(%Tab{} = tab, key, opts) do
    SpectreLens.Errors.safe(:save_session, fn -> Runtime.save_session(tab, key, opts) end)
  end

  @doc "Returns a stored logical browser session."
  @spec get_session(Runtime.t() | pid(), term()) :: {:ok, Session.t()} | {:error, term()}
  def get_session(runtime, key) do
    SpectreLens.Errors.safe(:get_session, fn -> Runtime.get_session(runtime, key) end)
  end

  @doc "Stores a logical browser session snapshot."
  @spec put_session(Runtime.t() | pid(), term(), Session.t() | map() | keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def put_session(runtime, key, session) do
    SpectreLens.Errors.safe(:put_session, fn -> Runtime.put_session(runtime, key, session) end)
  end

  @doc "Deletes a stored logical browser session."
  @spec delete_session(Runtime.t() | pid(), term()) :: :ok | {:error, term()}
  def delete_session(runtime, key) do
    SpectreLens.Errors.safe(:delete_session, fn -> Runtime.delete_session(runtime, key) end)
  end

  @doc "Exports a stored logical browser session as a JSON-safe map."
  @spec export_session(Runtime.t() | pid(), term()) :: {:ok, map()} | {:error, term()}
  def export_session(runtime, key) do
    SpectreLens.Errors.safe(:export_session, fn -> Runtime.export_session(runtime, key) end)
  end

  @doc "Imports a JSON-safe logical browser session snapshot."
  @spec import_session(Runtime.t() | pid(), term(), map() | keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def import_session(runtime, key, session) do
    SpectreLens.Errors.safe(:import_session, fn ->
      Runtime.import_session(runtime, key, session)
    end)
  end

  @doc "Closes a runtime and all Lightpanda instances it owns."
  @spec close(Runtime.t() | pid()) :: :ok | {:error, term()}
  def close(runtime), do: SpectreLens.Errors.safe(:close, fn -> Runtime.close(runtime) end)

  @doc """
  Looks at the current page and returns an agent-readable `%SpectreLens.View{}`.
  """
  @spec look(Tab.t(), keyword()) :: {:ok, View.t()} | {:error, term()}
  def look(%Tab{} = tab, opts \\ []) do
    SpectreLens.Errors.safe(:look, fn ->
      include = opts[:include] || @default_include
      context = %Context{tab: tab, include: List.wrap(include)}

      with {:ok, %Context{} = context} <- PlugPipeline.run(context, opts) do
        view =
          context.view
          |> Map.update!(:warnings, &Enum.reverse/1)
          |> Map.update!(:errors, &Enum.reverse/1)

        {:ok, view}
      end
    end)
  end

  @doc "Performs one browser action."
  @spec act(Tab.t(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def act(tab, action, opts \\ [])

  def act(tab, {:navigate, ref}, opts) do
    safe_action(fn ->
      with {:ok, url} <- ActionResolver.navigation_url(tab, ref, opts) do
        SpectreLens.Protocol.navigate(tab, url, opts)
      end
    end)
  end

  def act(tab, {:click, opts}, call_opts) when is_list(opts) do
    safe_action(fn ->
      with {:ok, ref} <- ActionResolver.clickable_ref(tab, opts, call_opts) do
        SpectreLens.Protocol.click(tab, ref, call_opts)
      end
    end)
  end

  def act(tab, {:click, ref}, opts),
    do: safe_action(fn -> SpectreLens.Protocol.click(tab, ref, opts) end)

  def act(tab, {:fill, opts}, call_opts) when is_list(opts),
    do: safe_action(fn -> SpectreLens.Protocol.fill(tab, opts[:ref], opts[:value], call_opts) end)

  def act(tab, {:submit, opts}, call_opts) when is_list(opts) do
    safe_action(fn ->
      SpectreLens.Protocol.submit(
        tab,
        opts[:ref] || opts[:form] || "form",
        opts[:fields] || %{},
        call_opts
      )
    end)
  end

  def act(tab, {:submit, ref}, opts),
    do: safe_action(fn -> SpectreLens.Protocol.submit(tab, ref, %{}, opts) end)

  def act(tab, {:scroll, opts}, call_opts) when is_list(opts),
    do: safe_action(fn -> SpectreLens.Protocol.scroll(tab, Keyword.merge(call_opts, opts)) end)

  def act(_tab, other, _opts), do: {:error, {:unknown_action, other}}

  @doc "Exports page artifacts."
  @spec export(Tab.t(), :screenshot | :html | :markdown | :pdf, keyword()) ::
          {:ok, binary()} | {:ok, Path.t()} | {:error, term()}
  def export(tab, type, opts \\ [])
  def export(tab, :screenshot, opts), do: safe_export(:screenshot, tab, opts)
  def export(tab, :html, opts), do: safe_export(:html, tab, opts)
  def export(tab, :markdown, opts), do: safe_export(:markdown, tab, opts)
  def export(tab, :pdf, opts), do: safe_export(:pdf, tab, opts)
  def export(_tab, other, _opts), do: {:error, {:unknown_export, other}}

  @doc """
  Zooms out from the page and returns a human-readable composition map.

  The returned `%SpectreLens.PageMap{}` describes the page in words for an
  agent: navigation, hero/intro, sidebars, content sections, galleries, forms,
  footer, and their approximate positions when available.
  """
  @spec zoom_out(Tab.t(), keyword()) :: {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  def zoom_out(%Tab{} = tab, opts \\ []) do
    SpectreLens.Errors.safe(:zoom_out, fn -> SpectreLens.Protocol.page_map(tab, opts) end)
  end

  @doc """
  Returns a compact section outline for the current page.

  Pass `:detailed`, `detailed: true`, or `detailed?: true` for a fuller outline.
  Pass a runtime with `url: "https://..."` to open a temporary tab for the outline.
  """
  @spec outline(Tab.t() | Runtime.t() | pid() | keyword(), keyword()) ::
          {:ok, Outline.t()} | {:error, term()}
  def outline(target, opts \\ [])

  def outline(opts, []) when is_list(opts) do
    opts = normalize_opts(opts)

    SpectreLens.Errors.safe(:outline, fn ->
      with {:ok, _url} <- Keyword.fetch(opts, :url),
           {:ok, runtime} <- open(runtime_opts(opts)) do
        try do
          outline(runtime, opts)
        after
          close(runtime)
        end
      else
        :error -> {:error, :missing_url}
        {:error, _} = error -> error
      end
    end)
  end

  def outline(%Tab{} = tab, opts) do
    opts = normalize_opts(opts)

    SpectreLens.Errors.safe(:outline, fn ->
      with {:ok, page_map} <- SpectreLens.Protocol.page_map(tab, Outline.page_map_opts(opts)) do
        {:ok, Outline.from_regions(page_map.regions, opts)}
      end
    end)
  end

  def outline(%Runtime{} = runtime, opts), do: outline(runtime.pid, opts)

  def outline(runtime, opts) when is_pid(runtime) do
    opts = normalize_opts(opts)

    SpectreLens.Errors.safe(:outline, fn ->
      with {:ok, url} <- Keyword.fetch(opts, :url),
           {:ok, tab} <- Runtime.new_tab(runtime, url: url) do
        try do
          with {:ok, page_map} <- SpectreLens.Protocol.page_map(tab, Outline.page_map_opts(opts)) do
            {:ok, Outline.from_regions(page_map.regions, opts)}
          end
        after
          SpectreLens.Protocol.close_tab(tab)
        end
      else
        :error -> {:error, :missing_url}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Discovers a small, goal-scoped navigation frontier for Elixir agents.

  Discovery is observation-only. It visits a capped same-origin frontier,
  scores links against `:goal`, and returns compact context plus ranked
  candidates. Pass `scorer: MyScorer` or `scorer: {MyScorer, opts}` to plug in
  a custom scorer implementing `SpectreLens.Discovery.Scorer`.
  """
  @spec discover(Tab.t() | Runtime.t() | pid() | binary() | keyword(), keyword()) ::
          {:ok, Discovery.t()} | {:error, term()}
  def discover(target, opts \\ [])

  def discover(opts, []) when is_list(opts) do
    opts = normalize_opts(opts)

    SpectreLens.Errors.safe(:discover, fn ->
      with {:ok, _url} <- Keyword.fetch(opts, :url),
           {:ok, runtime} <- open(runtime_opts(opts)) do
        try do
          discover(runtime, opts)
        after
          close(runtime)
        end
      else
        :error -> {:error, :missing_url}
        {:error, _} = error -> error
      end
    end)
  end

  def discover(url, opts) when is_binary(url) do
    opts
    |> Keyword.put(:url, url)
    |> discover([])
  end

  def discover(%Tab{} = tab, opts) do
    opts = normalize_opts(opts)
    SpectreLens.Errors.safe(:discover, fn -> Discovery.run(tab, opts) end)
  end

  def discover(%Runtime{} = runtime, opts), do: discover(runtime.pid, opts)

  def discover(runtime, opts) when is_pid(runtime) do
    opts = normalize_opts(opts)

    SpectreLens.Errors.safe(:discover, fn ->
      with {:ok, url} <- Keyword.fetch(opts, :url),
           {:ok, tab} <- Runtime.new_tab(runtime, url: url) do
        try do
          Discovery.run(tab, opts)
        after
          SpectreLens.Protocol.close_tab(tab)
        end
      else
        :error -> {:error, :missing_url}
        {:error, _} = error -> error
      end
    end)
  end

  @doc "Alias for `zoom_out/2`, useful when an agent wants to step back from a focused element."
  @spec unfocus(Tab.t(), keyword()) :: {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  def unfocus(%Tab{} = tab, opts \\ []), do: zoom_out(tab, opts)

  @doc "Zooms into one selector, action ref, or region and describes that local area."
  @spec zoom_in(Tab.t(), term(), keyword()) :: {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  def zoom_in(tab, ref, opts \\ [])

  def zoom_in(%Tab{} = tab, %Region{selector: selector}, opts) when is_binary(selector) do
    zoom_in(tab, selector, opts)
  end

  def zoom_in(%Tab{} = tab, %Outline.Section{selector: selector}, opts)
      when is_binary(selector) do
    zoom_in(tab, selector, opts)
  end

  def zoom_in(%Tab{} = tab, ref, opts) do
    SpectreLens.Errors.safe(:zoom_in, fn -> SpectreLens.Protocol.focus(tab, ref, opts) end)
  end

  @doc "Starts a lightweight polling watcher for a tab."
  @spec watch(Tab.t(), keyword()) :: {:ok, Watcher.t()} | {:error, term()}
  def watch(%Tab{} = tab, opts \\ []) do
    SpectreLens.Errors.safe(:watch, fn -> Watcher.start(tab, opts) end)
  end

  @doc "Stops a watcher."
  @spec stop_watch(Watcher.t()) :: :ok | {:error, term()}
  def stop_watch(%Watcher{} = watcher) do
    SpectreLens.Errors.safe(:stop_watch, fn -> Watcher.stop(watcher) end)
  end

  @doc "Sends a raw CDP command to a tab."
  @spec cdp(Tab.t(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def cdp(%Tab{} = tab, method, params \\ %{}, opts \\ []) do
    SpectreLens.Errors.safe(:cdp, fn ->
      SpectreLens.Protocol.command(tab, method, params, opts)
    end)
  end

  @doc "Returns runtime diagnostics for the Lightpanda binary."
  @spec doctor(keyword()) :: map() | {:error, term()}
  def doctor(opts \\ []) do
    SpectreLens.Errors.safe(:doctor, fn -> SpectreLens.Lightpanda.doctor(opts) end)
  end

  @doc """
  Discovers and parses a site's `llms.txt` agent context file.

  Pass either a site URL, a direct `/llms.txt` URL, a direct `/llms-full.txt`
  URL, or a `%SpectreLens.Tab{}`. Use `full?: true` to also fetch the full
  context file when the site exposes one.
  """
  @spec llms(binary() | Tab.t(), keyword()) :: {:ok, LlmsTxt.t()} | {:error, term()}
  def llms(url_or_tab, opts \\ [])

  def llms(%Tab{} = tab, opts) do
    SpectreLens.Errors.safe(:llms, fn ->
      with {:ok, url} <- SpectreLens.Protocol.url(tab) do
        LlmsTxt.discover(url, opts)
      end
    end)
  end

  def llms(url, opts) when is_binary(url) do
    SpectreLens.Errors.safe(:llms, fn -> LlmsTxt.discover(url, opts) end)
  end

  @doc """
  Returns Markdown context from a site's `llms.txt` / full context file.

  Options are forwarded to `llms/2`. Set `prefer: :index | :full | :both` to
  choose which Markdown document is returned. The default is `:full`.
  """
  @spec llms_context(binary() | Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def llms_context(url_or_tab, opts \\ []) do
    SpectreLens.Errors.safe(:llms_context, fn ->
      with {:ok, doc} <- llms(url_or_tab, Keyword.put_new(opts, :full?, true)) do
        LlmsTxt.to_context(doc, opts)
      end
    end)
  end

  @doc "Converts an error into an agent-readable packet with retry guidance."
  @spec explain_error(term()) :: SpectreLens.Errors.agent_error()
  def explain_error(reason), do: SpectreLens.Errors.to_agent(reason)

  @doc "Returns the package version."
  @spec version() :: binary()
  def version do
    :spectre_lens
    |> Application.spec(:vsn)
    |> to_string()
  end

  @spec safe_action((-> result)) :: result | {:error, term()} when result: term()
  defp safe_action(fun) do
    SpectreLens.Errors.safe(:act, fun)
  end

  @spec runtime_opts(keyword()) :: keyword()
  defp runtime_opts(opts) do
    Keyword.take(opts, [:binary, :driver, :host, :instances, :port, :ports, :serve_args, :timeout])
  end

  @spec normalize_opts(list()) :: keyword()
  defp normalize_opts(opts) do
    Enum.map(opts, fn
      {key, value} -> {key, value}
      key when is_atom(key) -> {key, true}
    end)
  end

  @spec safe_export(:screenshot | :html | :markdown | :pdf, Tab.t(), keyword()) ::
          {:ok, binary()} | {:ok, Path.t()} | {:error, term()}
  defp safe_export(:screenshot, tab, opts) do
    SpectreLens.Errors.safe(:export, fn ->
      with {:ok, data} <- SpectreLens.Protocol.screenshot(tab, opts) do
        maybe_write_export(data, opts)
      end
    end)
  end

  defp safe_export(:html, tab, opts) do
    SpectreLens.Errors.safe(:export, fn ->
      with {:ok, data} <- SpectreLens.Protocol.html(tab, opts) do
        maybe_write_export(data, opts)
      end
    end)
  end

  defp safe_export(:markdown, tab, opts) do
    SpectreLens.Errors.safe(:export, fn ->
      with {:ok, data} <- SpectreLens.Protocol.markdown(tab, opts) do
        maybe_write_export(data, opts)
      end
    end)
  end

  defp safe_export(:pdf, tab, opts) do
    SpectreLens.Errors.safe(:export, fn ->
      with {:ok, data} <- SpectreLens.Protocol.pdf(tab, opts) do
        maybe_write_export(data, opts)
      end
    end)
  end

  @spec maybe_write_export(binary(), keyword()) ::
          {:ok, binary()} | {:ok, Path.t()} | {:error, term()}
  defp maybe_write_export(data, opts) do
    case opts[:path] || opts[:to] do
      nil ->
        {:ok, data}

      path when is_binary(path) ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, data) do
          {:ok, path}
        end
    end
  end
end
