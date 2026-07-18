defmodule SpectreLens.Discovery do
  @moduledoc """
  Goal-scoped site discovery for agents.

  Discovery is intentionally observation-only: it navigates through a small,
  capped same-origin frontier and returns compact context plus ranked candidate
  links and forms. Scoring is deterministic by default, but callers can provide
  a scorer module that implements `SpectreLens.Discovery.Scorer`.
  """

  alias SpectreLens.Discovery.{Candidate, Page, State}
  alias SpectreLens.{Outline, Tab, View}

  @default_max_depth 2
  @default_max_pages 8
  @default_max_links_per_page 40
  @default_max_candidates 20

  @type t :: %__MODULE__{
          text: binary(),
          goal: binary(),
          root_url: binary(),
          visited: [Page.t()],
          candidates: [Candidate.t()],
          forms: [map()],
          trust: :untrusted,
          warnings: [term()],
          errors: [term()]
        }

  defstruct text: "",
            goal: "",
            root_url: "",
            visited: [],
            candidates: [],
            forms: [],
            trust: :untrusted,
            warnings: [],
            errors: []

  @doc false
  @spec run(Tab.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(%Tab{} = tab, opts) do
    with {:ok, goal} <- fetch_goal(opts),
         {:ok, root_url} <- SpectreLens.Protocol.url(tab) do
      root_url = canonical_url(root_url) || root_url
      {scorer, scorer_opts} = scorer(opts)

      state = %State{
        tab: tab,
        goal: goal,
        root_url: root_url,
        origin: origin_key(root_url),
        scorer: scorer,
        scorer_opts: scorer_opts,
        opts: opts,
        queue: :queue.from_list([{root_url, 0}]),
        seen: MapSet.new([root_url]),
        current_url: root_url
      }

      state
      |> crawl()
      |> finalize()
    end
  end

  @spec fetch_goal(keyword()) :: {:ok, binary()} | {:error, :missing_goal}
  defp fetch_goal(opts) do
    case Keyword.get(opts, :goal) do
      goal when is_binary(goal) ->
        goal = String.trim(goal)
        if goal == "", do: {:error, :missing_goal}, else: {:ok, goal}

      _ ->
        {:error, :missing_goal}
    end
  end

  @spec crawl(State.t()) :: State.t()
  defp crawl(%State{} = state) do
    if crawl_complete?(state) do
      state
    else
      state
      |> take_next_page()
      |> crawl()
    end
  end

  @spec crawl_complete?(State.t()) :: boolean()
  defp crawl_complete?(%State{} = state) do
    state.visited_count >= max_pages(state.opts) or :queue.is_empty(state.queue)
  end

  @spec take_next_page(State.t()) :: State.t()
  defp take_next_page(%State{} = state) do
    {{:value, {url, depth}}, queue} = :queue.out(state.queue)
    state = %{state | queue: queue}

    if depth > max_depth(state.opts), do: state, else: visit(state, url, depth)
  end

  @spec visit(State.t(), binary(), non_neg_integer()) :: State.t()
  defp visit(%State{} = state, url, depth) do
    with :ok <- maybe_navigate(state, url),
         {:ok, page, forms, candidates, warnings, errors} <- inspect_page(state, url, depth) do
      candidates = cap_page_candidates(candidates, url, state, warnings)
      {kept_candidates, cap_warnings} = candidates

      %{
        state
        | current_url: url,
          visited: [page | state.visited],
          visited_count: state.visited_count + 1,
          forms: forms ++ state.forms,
          candidates: kept_candidates ++ state.candidates,
          warnings: cap_warnings ++ warnings ++ state.warnings,
          errors: errors ++ state.errors
      }
      |> enqueue_candidates(kept_candidates, depth + 1)
    else
      {:error, reason} ->
        %{state | errors: [{:visit_failed, url, reason} | state.errors]}
    end
  end

  @spec maybe_navigate(State.t(), binary()) :: :ok | {:error, term()}
  defp maybe_navigate(%{current_url: url}, url), do: :ok

  defp maybe_navigate(%{opts: opts} = state, url) do
    SpectreLens.Protocol.navigate(state.tab, url, opts)
  end

  @spec inspect_page(State.t(), binary(), non_neg_integer()) ::
          {:ok, Page.t(), [map()], [Candidate.t()], [term()], [term()]} | {:error, term()}
  defp inspect_page(state, url, depth) do
    tab = state.tab
    include = Keyword.get(state.opts, :include, [:markdown, :interactive, :forms, :links])
    look_opts = state.opts |> Keyword.put(:include, include) |> Keyword.put(:llms?, false)

    with {:ok, view} <- SpectreLens.look(tab, look_opts),
         {:ok, outline} <- SpectreLens.outline(tab, state.opts) do
      page = page_from_view(url, depth, view, outline)
      forms = forms_from_view(view, url, depth)
      {candidates, warnings} = candidates_from_view(view, outline, state, page, depth)
      {:ok, page, forms, candidates, warnings, view.errors}
    end
  end

  @spec page_from_view(binary(), non_neg_integer(), View.t(), Outline.t()) :: Page.t()
  defp page_from_view(url, depth, %View{} = view, %Outline{} = outline) do
    %Page{
      url: canonical_url(view.url || url) || url,
      title: view.title,
      outline: outline,
      summary: summary(view.markdown, outline),
      depth: depth,
      hash: view_hash(view)
    }
  end

  @spec forms_from_view(View.t(), binary(), non_neg_integer()) :: [map()]
  defp forms_from_view(%View{forms: forms}, url, depth) do
    Enum.map(forms, fn form ->
      form
      |> Map.put_new(:source_url, url)
      |> Map.put_new(:depth, depth)
    end)
  end

  @spec candidates_from_view(View.t(), Outline.t(), State.t(), Page.t(), non_neg_integer()) ::
          {[Candidate.t()], [term()]}
  defp candidates_from_view(%View{} = view, %Outline{} = outline, state, page, depth) do
    links = view.links

    candidates =
      links
      |> Enum.map(&candidate_from_link(&1, state, page.url, depth, outline))
      |> Enum.reject(&is_nil/1)
      |> score_candidates(state, page, outline, view, depth)

    candidate_count = length(candidates)
    link_count = length(links)

    warnings =
      if candidate_count < link_count do
        [{:links_filtered, page.url, link_count, candidate_count}]
      else
        []
      end

    {candidates, warnings}
  end

  @spec candidate_from_link(map(), State.t(), binary(), non_neg_integer(), Outline.t()) ::
          Candidate.t() | nil
  defp candidate_from_link(link, state, source_url, depth, outline) do
    href = get_any(link, :href) || get_any(link, "href")

    with url when is_binary(url) <- normalize_link(href, source_url, state),
         false <- MapSet.member?(state.seen, url) do
      text = get_any(link, :text) || get_any(link, "text") || get_any(link, :title) || url

      %Candidate{
        url: url,
        text: blank_to_nil(text),
        selector: get_any(link, :selector) || get_any(link, "selector"),
        source_url: source_url,
        region: region_for_link(text, outline),
        score: 0.0,
        reason: nil,
        metadata: %{link: link, depth: depth}
      }
    else
      _ -> nil
    end
  end

  @spec score_candidates(
          [Candidate.t()],
          State.t(),
          Page.t(),
          Outline.t(),
          View.t(),
          non_neg_integer()
        ) ::
          [Candidate.t()]
  defp score_candidates(candidates, state, page, outline, view, depth) do
    context = %{
      goal: state.goal,
      root_url: state.root_url,
      page: page,
      outline: outline,
      view: view,
      depth: depth,
      visited: Enum.reverse(state.visited)
    }

    candidates
    |> Enum.reduce([], fn candidate, acc ->
      case state.scorer.score_candidate(candidate, context, state.scorer_opts) do
        {:ok, %Candidate{} = candidate} -> [candidate | acc]
        {:skip, _reason} -> acc
        {:error, _reason} -> acc
      end
    end)
    |> Enum.reverse()
    |> rank_candidates(state.scorer, context, state.scorer_opts)
  end

  @spec rank_candidates([Candidate.t()], module(), map(), keyword()) :: [Candidate.t()]
  defp rank_candidates(candidates, scorer, context, scorer_opts) do
    case scorer.rank_candidates(candidates, context, scorer_opts) do
      {:ok, ranked} when is_list(ranked) -> ranked
      _ -> Enum.sort_by(candidates, & &1.score, :desc)
    end
  end

  @spec cap_page_candidates([Candidate.t()], binary(), State.t(), [term()]) ::
          {[Candidate.t()], [term()]}
  defp cap_page_candidates(candidates, url, state, _warnings) do
    max = max_links_per_page(state.opts)
    kept = Enum.take(candidates, max)
    candidate_count = length(candidates)

    warnings =
      if candidate_count > max do
        [{:links_truncated, url, candidate_count, length(kept)}]
      else
        []
      end

    {kept, warnings}
  end

  @spec enqueue_candidates(State.t(), [Candidate.t()], non_neg_integer()) :: State.t()
  defp enqueue_candidates(%State{} = state, candidates, depth) do
    if depth > max_depth(state.opts) do
      state
    else
      Enum.reduce(candidates, state, &enqueue_candidate(&1, &2, depth))
    end
  end

  @spec enqueue_candidate(Candidate.t(), State.t(), non_neg_integer()) :: State.t()
  defp enqueue_candidate(candidate, state, depth) do
    cond do
      state.visited_count + :queue.len(state.queue) >= max_pages(state.opts) ->
        state

      MapSet.member?(state.seen, candidate.url) ->
        state

      true ->
        %{
          state
          | queue: :queue.in({candidate.url, depth}, state.queue),
            seen: MapSet.put(state.seen, candidate.url)
        }
    end
  end

  @spec finalize(State.t()) :: {:ok, t()}
  defp finalize(%State{} = state) do
    visited = Enum.reverse(state.visited)
    candidates = final_candidates(state, visited)

    discovery = %__MODULE__{
      goal: state.goal,
      root_url: state.root_url,
      visited: visited,
      candidates: candidates,
      forms: Enum.reverse(state.forms),
      warnings: Enum.reverse(state.warnings),
      errors: Enum.reverse(state.errors)
    }

    text =
      discovery
      |> render_text()
      |> SpectreLens.UntrustedContent.wrap(discovery.root_url)

    {:ok, %{discovery | text: text}}
  end

  @spec final_candidates(State.t(), [Page.t()]) :: [Candidate.t()]
  defp final_candidates(%State{} = state, visited) do
    context = %{goal: state.goal, root_url: state.root_url, visited: visited}

    state.candidates
    |> Enum.reverse()
    |> rank_candidates(state.scorer, context, state.scorer_opts)
    |> Enum.take(max_candidates(state.opts))
  end

  @spec render_text(t()) :: binary()
  defp render_text(%__MODULE__{} = discovery) do
    [
      "# Discovery",
      "",
      "Goal: #{discovery.goal}",
      "Root: #{discovery.root_url}",
      "",
      "## Visited",
      render_pages(discovery.visited),
      "",
      "## Best Candidates",
      render_candidates(discovery.candidates),
      "",
      "## Forms",
      render_forms(discovery.forms),
      "",
      "## Warnings",
      render_terms(discovery.warnings),
      "",
      "## Errors",
      render_terms(discovery.errors)
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  @spec render_pages([Page.t()]) :: binary()
  defp render_pages([]), do: "- none"

  defp render_pages(pages) do
    Enum.map_join(pages, "\n", fn page ->
      title = page.title || page.url
      "- depth #{page.depth}: #{title} (#{page.url})"
    end)
  end

  @spec render_candidates([Candidate.t()]) :: binary()
  defp render_candidates([]), do: "- none"

  defp render_candidates(candidates) do
    Enum.map_join(candidates, "\n", fn candidate ->
      label = candidate.text || candidate.url
      reason = if candidate.reason, do: " - #{candidate.reason}", else: ""
      "- #{Float.round(candidate.score, 3)} #{label} -> #{candidate.url}#{reason}"
    end)
  end

  @spec render_forms([map()]) :: binary()
  defp render_forms([]), do: "- none"

  defp render_forms(forms) do
    Enum.map_join(forms, "\n", fn form ->
      label = get_any(form, :name) || get_any(form, "name") || get_any(form, :id) || "form"
      source = get_any(form, :source_url) || get_any(form, "source_url")
      "- #{label} on #{source}"
    end)
  end

  @spec render_terms([term()]) :: binary()
  defp render_terms([]), do: "- none"
  defp render_terms(terms), do: Enum.map_join(terms, "\n", &"- #{inspect(&1)}")

  @spec summary(binary() | nil, Outline.t()) :: binary() | nil
  defp summary(markdown, outline) when is_binary(markdown) do
    markdown
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 320)
    |> blank_to_nil()
    |> Kernel.||(outline_summary(outline))
  end

  defp summary(_markdown, outline), do: outline_summary(outline)

  @spec outline_summary(Outline.t()) :: binary() | nil
  defp outline_summary(%Outline{text: text}) when is_binary(text) do
    text |> String.replace("\n", " ") |> String.slice(0, 320) |> blank_to_nil()
  end

  @spec normalize_link(term(), binary(), map()) :: binary() | nil
  defp normalize_link(href, source_url, state) when is_binary(href) do
    with {:ok, absolute} <- URI.new(href),
         absolute <- URI.merge(source_url, absolute),
         true <- allowed_scheme?(absolute.scheme),
         canonical when is_binary(canonical) <- canonical_url(URI.to_string(absolute)),
         true <- same_origin_allowed?(canonical, state) do
      canonical
    else
      _ -> nil
    end
  end

  defp normalize_link(_href, _source_url, _state), do: nil

  @spec canonical_url(binary()) :: binary() | nil
  defp canonical_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) ->
        uri
        |> Map.put(:fragment, nil)
        |> normalize_path()
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp canonical_url(_url), do: nil

  @spec normalize_path(URI.t()) :: URI.t()
  defp normalize_path(%URI{path: nil} = uri), do: %{uri | path: "/"}
  defp normalize_path(%URI{path: ""} = uri), do: %{uri | path: "/"}
  defp normalize_path(uri), do: uri

  @spec same_origin_allowed?(binary(), map()) :: boolean()
  defp same_origin_allowed?(url, %{opts: opts, origin: origin}) do
    not Keyword.get(opts, :same_origin?, true) or origin_key(url) == origin
  end

  @spec origin_key(binary()) :: {binary() | nil, binary() | nil, integer() | nil}
  defp origin_key(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port}
  end

  @spec allowed_scheme?(binary() | nil) :: boolean()
  defp allowed_scheme?(scheme), do: scheme in ["http", "https"]

  @spec region_for_link(term(), Outline.t()) :: atom() | nil
  defp region_for_link(text, %Outline{sections: sections}) when is_binary(text) do
    normalized = normalize_text(text)

    Enum.find_value(sections, fn section ->
      labels = [section.label, section.title | section.links || []]

      if Enum.any?(labels, &(normalize_text(&1) == normalized)) do
        section.purpose
      end
    end)
  end

  defp region_for_link(_text, _outline), do: nil

  @spec view_hash(View.t()) :: binary()
  defp view_hash(%View{} = view) do
    [
      view.url,
      view.title,
      view.markdown,
      Jason.encode!(view.links),
      Jason.encode!(view.forms),
      Jason.encode!(view.interactive)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec scorer(keyword()) :: {module(), keyword()}
  defp scorer(opts) do
    case Keyword.get(opts, :scorer, SpectreLens.Discovery.DeterministicScorer) do
      {module, scorer_opts} -> {module, List.wrap(scorer_opts)}
      module -> {module, []}
    end
  end

  @spec max_depth(keyword()) :: non_neg_integer()
  defp max_depth(opts), do: Keyword.get(opts, :max_depth, @default_max_depth)

  @spec max_pages(keyword()) :: pos_integer()
  defp max_pages(opts), do: Keyword.get(opts, :max_pages, @default_max_pages)

  @spec max_links_per_page(keyword()) :: non_neg_integer()
  defp max_links_per_page(opts),
    do: Keyword.get(opts, :max_links_per_page, @default_max_links_per_page)

  @spec max_candidates(keyword()) :: non_neg_integer()
  defp max_candidates(opts), do: Keyword.get(opts, :max_candidates, @default_max_candidates)

  @spec get_any(term(), term(), term()) :: term()
  defp get_any(map, key, default \\ nil)
  defp get_any(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get_any(_map, _key, default), do: default

  @spec blank_to_nil(term()) :: term() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  @spec normalize_text(term()) :: binary()
  defp normalize_text(nil), do: ""

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize_text(other), do: other |> to_string() |> normalize_text()
end
