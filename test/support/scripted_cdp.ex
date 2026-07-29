defmodule SpectreLens.TestCDP do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  def queue_reply(pid, method, reply) do
    GenServer.call(pid, {:queue_reply, method, reply})
  end

  def commands(pid), do: GenServer.call(pid, :commands)

  def emit(pid, method, session_id, params \\ %{}) do
    GenServer.cast(pid, {:emit, method, session_id, params})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.get(opts, :owner, self()),
       replies: %{},
       commands: [],
       waiters: %{},
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:queue_reply, method, reply}, _from, state) do
    replies = Map.update(state.replies, method, [reply], &(&1 ++ [reply]))
    {:reply, :ok, %{state | replies: replies}}
  end

  def handle_call(:commands, _from, state) do
    {:reply, Enum.reverse(state.commands), state}
  end

  @impl GenServer
  def handle_cast({:emit, method, session_id, params}, state) do
    {:noreply, dispatch_event(state, method, session_id, params)}
  end

  @impl GenServer
  def handle_info(
        {:"$websockex_cast", {:send_command, method, params, session_id, from, ref}},
        state
      ) do
    send(state.owner, {:test_cdp_command, method, params, session_id})
    {reply, state} = next_reply(state, method, params, session_id)
    deliver_reply(from, ref, reply)

    state =
      if navigation_command?(method, params) do
        dispatch_event(state, "Page.loadEventFired", session_id, %{"timestamp" => 1})
      else
        state
      end

    command = %{method: method, params: params, session_id: session_id, reply: reply}
    {:noreply, %{state | commands: [command | state.commands]}}
  end

  def handle_info(
        {:"$websockex_cast", {:wait_event, method, session_id, from, ref}},
        state
      ) do
    key = {method, session_id}
    waiters = Map.update(state.waiters, key, [{from, ref}], &(&1 ++ [{from, ref}]))
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(
        {:"$websockex_cast", {:cancel_event_waiter, from, ref}},
        state
      ) do
    waiters =
      Map.new(state.waiters, fn {key, entries} ->
        {key, Enum.reject(entries, &(&1 == {from, ref}))}
      end)
      |> Enum.reject(fn {_key, entries} -> entries == [] end)
      |> Map.new()

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info({:"$websockex_cast", {:cancel_command, _from, _ref}}, state),
    do: {:noreply, state}

  def handle_info(
        {:"$websockex_cast", {:subscribe_event, method, session_id, subscriber}},
        state
      ) do
    key = {method, session_id}
    subscribers = Map.update(state.subscribers, key, [subscriber], &Enum.uniq([subscriber | &1]))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(
        {:"$websockex_cast", {:unsubscribe_event, method, session_id, subscriber}},
        state
      ) do
    key = {method, session_id}

    subscribers =
      case Map.get(state.subscribers, key, []) |> List.delete(subscriber) do
        [] -> Map.delete(state.subscribers, key)
        remaining -> Map.put(state.subscribers, key, remaining)
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:"$websockex_cast", :close}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp next_reply(state, method, params, session_id) do
    case Map.get(state.replies, method, []) do
      [reply | rest] ->
        replies =
          if rest == [],
            do: Map.delete(state.replies, method),
            else: Map.put(state.replies, method, rest)

        {resolve_reply(reply, method, params, session_id), %{state | replies: replies}}

      [] ->
        {default_reply(method, params), state}
    end
  end

  defp resolve_reply(reply, method, params, session_id) when is_function(reply, 3),
    do: reply.(method, params, session_id)

  defp resolve_reply(reply, _method, _params, _session_id), do: reply

  defp deliver_reply(_from, _ref, :ignore), do: :ok

  defp deliver_reply(from, ref, {:error, code, message}) do
    send(from, {:spectre_lens_cdp_error, ref, %{"code" => code, "message" => message}})
  end

  defp deliver_reply(from, ref, {:error, error}) do
    send(from, {:spectre_lens_cdp_error, ref, error})
  end

  defp deliver_reply(from, ref, {:ok, result}) do
    send(from, {:spectre_lens_cdp_response, ref, result})
  end

  defp dispatch_event(state, method, session_id, params) do
    keys = Enum.uniq([{method, session_id}, {method, nil}])

    keys
    |> Enum.flat_map(&Map.get(state.subscribers, &1, []))
    |> Enum.uniq()
    |> Enum.each(fn subscriber ->
      send(
        subscriber,
        {:spectre_lens_cdp_event, self(), method, session_id, params}
      )
    end)

    {waiters, remaining} =
      Enum.reduce_while(keys, {[], state.waiters}, fn key, {found, waiters} ->
        case Map.pop(waiters, key) do
          {nil, waiters} -> {:cont, {found, waiters}}
          {entries, waiters} -> {:halt, {entries, waiters}}
        end
      end)

    Enum.each(waiters, fn {from, ref} ->
      send(from, {:spectre_lens_cdp_event, ref, params})
    end)

    %{state | waiters: remaining}
  end

  defp default_reply("Target.createBrowserContext", _params),
    do: {:ok, %{"browserContextId" => "context-1"}}

  defp default_reply("Target.createTarget", _params), do: {:ok, %{"targetId" => "target-1"}}

  defp default_reply("Target.attachToTarget", _params),
    do: {:ok, %{"sessionId" => "session-1"}}

  defp default_reply("DOM.getDocument", _params), do: {:ok, %{"root" => %{"nodeId" => 1}}}

  defp default_reply("DOM.getOuterHTML", _params),
    do: {:ok, %{"outerHTML" => "<html><body>Example</body></html>"}}

  defp default_reply("DOM.querySelector", params) do
    selector = Map.get(params, :selector, Map.get(params, "selector"))
    {:ok, %{"nodeId" => if(selector == "#missing", do: 0, else: 42)}}
  end

  defp default_reply("DOM.pushNodesByBackendIdsToFrontend", _params),
    do: {:ok, %{"nodeIds" => [43]}}

  defp default_reply("DOM.getBoxModel", _params),
    do: {:ok, %{"model" => %{"content" => [0, 0, 10, 0, 10, 20, 0, 20]}}}

  defp default_reply("DOM.resolveNode", _params),
    do: {:ok, %{"object" => %{"objectId" => "object-1"}}}

  defp default_reply("Accessibility.getFullAXTree", _params) do
    {:ok,
     %{
       "nodes" => [
         %{"nodeId" => "1", "role" => %{"value" => "heading"}, "name" => %{"value" => "Example"}},
         %{"nodeId" => "2", "role" => "button", "name" => ""}
       ]
     }}
  end

  defp default_reply("Page.captureScreenshot", _params),
    do: {:ok, %{"data" => Base.encode64("png-bytes")}}

  defp default_reply("Page.printToPDF", _params),
    do: {:ok, %{"data" => Base.encode64("pdf-bytes")}}

  defp default_reply("Storage.getCookies", _params),
    do: {:ok, %{"cookies" => [%{"name" => "sid", "value" => "secret"}]}}

  defp default_reply("LP.getMarkdown", _params), do: {:ok, %{"markdown" => "# Native"}}
  defp default_reply("LP.getSemanticTree", _params), do: {:ok, %{"tree" => %{"role" => "main"}}}

  defp default_reply("LP.getInteractiveElements", _params),
    do: {:ok, %{"elements" => [%{"role" => "button", "name" => "Save"}]}}

  defp default_reply("LP.getStructuredData", _params),
    do: {:ok, %{"structuredData" => %{"title" => "Example"}}}

  defp default_reply("Runtime.evaluate", params) do
    expression = Map.get(params, :expression, Map.get(params, "expression", ""))
    {:ok, %{"result" => %{"value" => evaluated_value(expression)}}}
  end

  defp default_reply(_method, _params), do: {:ok, %{}}

  defp navigation_command?(method, _params) when method in ["Page.navigate", "Page.reload"],
    do: true

  defp navigation_command?("Runtime.evaluate", params) do
    params
    |> Map.get(:expression, Map.get(params, "expression", ""))
    |> String.contains?("requestSubmit")
  end

  defp navigation_command?(_method, _params), do: false

  defp evaluated_value("window.location.href"), do: "https://example.com/page"
  defp evaluated_value("document.title"), do: "Example title"
  defp evaluated_value("window.location.origin"), do: "https://example.com"

  defp evaluated_value(expression) do
    case evaluated_runtime_value(expression) do
      {:ok, value} -> value
      :unmatched -> evaluated_projection_value(expression)
    end
  end

  defp evaluated_runtime_value(expression) do
    cond do
      String.contains?(expression, "htmlLength") ->
        {:ok, %{"usable" => true, "htmlLength" => 100, "childCount" => 2}}

      String.contains?(expression, "localStorage: copy") ->
        {:ok,
         %{
           "localStorage" => %{"theme" => "dark"},
           "sessionStorage" => %{"step" => "2"}
         }}

      String.contains?(expression, "data-spectre-lens-ref") ->
        {:ok, ~s([data-spectre-lens-ref="link-1"])}

      true ->
        :unmatched
    end
  end

  defp evaluated_projection_value(expression) do
    cond do
      String.contains?(expression, "const maxRegions") ->
        page_regions()

      String.contains?(expression, "Array.from(document.forms)") ->
        [%{"id" => "search", "fields" => [%{"name" => "q", "label" => "Query"}]}]

      String.contains?(expression, "querySelectorAll('a[href]')") ->
        [%{"href" => "https://example.com/docs", "text" => "Docs", "selector" => "#docs"}]

      String.contains?(expression, "querySelectorAll('script[type=\"application/ld+json\"]')") ->
        %{"json_ld" => [%{"@type" => "Article"}], "meta" => %{}}

      String.contains?(expression, "const cssPath = el") ->
        [%{"role" => "button", "name" => "Save", "selector" => "#save"}]

      String.contains?(expression, "const renderChildren") ->
        "# Example\n\nBody"

      true ->
        true
    end
  end

  defp page_regions do
    purposes = [
      "navigation",
      "hero",
      "sidebar",
      "gallery",
      "contact_form",
      "search_form",
      "form",
      "footer",
      "link_collection",
      "content_section",
      "unknown"
    ]

    Enum.with_index(purposes, fn purpose, index ->
      %{
        "id" => "region-#{index}",
        "kind" => if(index == 0, do: "banner", else: "section"),
        "purpose" => purpose,
        "label" => if(rem(index, 2) == 0, do: "Region #{index}", else: " "),
        "position" => "top #{index}",
        "text" => if(index == 10, do: " ", else: "Useful region text #{index}"),
        "selector" => "#region-#{index}",
        "links" =>
          if(index == 0,
            do: [%{"text" => "Home"}, %{"href" => "/docs"}, %{}],
            else: []
          ),
        "fields" =>
          if(index == 4,
            do: [%{"label" => "Email"}, %{"name" => "message"}, %{"type" => "submit"}],
            else: []
          ),
        "stats" => %{"images" => if(index == 3, do: 4, else: 0)}
      }
    end)
  end
end
