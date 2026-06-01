defmodule SpectreLens.Discovery.DeterministicScorer do
  @moduledoc "Default deterministic scorer for goal-scoped discovery."

  @behaviour SpectreLens.Discovery.Scorer

  alias SpectreLens.Discovery.Candidate

  @stopwords MapSet.new(~w(
    a an and are as at be by for from has have in into is it its of on or the
    to with your you
  ))

  @boilerplate ~w(
    about account archive author blog cookie cookies contact copyright faq feed
    legal login logout privacy rss sign sitemap tag tags terms
  )

  @impl true
  def score_candidate(%Candidate{url: url} = candidate, context, opts) when is_binary(url) do
    goal_tokens = goal_tokens(context[:goal] || "")
    text = normalize(candidate.text || "")
    url_text = normalize(url_path_text(url))
    page_text = normalize(page_context_text(context))

    {score, matches} =
      Enum.reduce(goal_tokens, {0.0, []}, fn token, {score, matches} ->
        cond do
          contains_token?(text, token) ->
            {score + 1.0, [token | matches]}

          contains_token?(url_text, token) ->
            {score + 0.8, [token | matches]}

          contains_token?(page_text, token) ->
            {score + 0.25, [token | matches]}

          true ->
            {score, matches}
        end
      end)

    score =
      score
      |> add_region_boost(candidate.region)
      |> add_search_boost(candidate, goal_tokens)
      |> add_depth_penalty(context[:depth] || 0)
      |> add_boilerplate_penalty(candidate, matches)
      |> max(0.0)

    min_score = Keyword.get(opts, :min_score, 0.0)

    if score < min_score do
      {:skip, :below_min_score}
    else
      {:ok,
       %{
         candidate
         | score: score,
           reason: reason(score, matches, candidate),
           metadata:
             candidate.metadata
             |> Map.put(:goal_matches, Enum.reverse(matches))
             |> Map.put(:url_pattern, url_pattern(candidate.url))
       }}
    end
  end

  def score_candidate(%Candidate{}, _context, _opts), do: {:skip, :missing_url}

  @impl true
  def rank_candidates(candidates, _context, _opts) do
    ranked =
      candidates
      |> Enum.sort_by(&{-&1.score, &1.url})
      |> apply_pattern_penalties()
      |> Enum.sort_by(&{-&1.score, &1.url})

    {:ok, ranked}
  end

  @spec apply_pattern_penalties([Candidate.t()]) :: [Candidate.t()]
  defp apply_pattern_penalties(candidates) do
    {_seen, ranked} =
      Enum.reduce(candidates, {%{}, []}, fn candidate, {seen, acc} ->
        pattern = candidate.metadata[:url_pattern] || url_pattern(candidate.url)
        count = Map.get(seen, pattern, 0)
        seen = Map.put(seen, pattern, count + 1)

        candidate =
          if count > 0 do
            %{
              candidate
              | score: max(candidate.score - min(0.15 * count, 0.6), 0.0),
                reason: append_reason(candidate.reason, "duplicate URL pattern penalty")
            }
          else
            candidate
          end

        {seen, [candidate | acc]}
      end)

    Enum.reverse(ranked)
  end

  @spec goal_tokens(binary()) :: [binary()]
  defp goal_tokens(goal) do
    goal
    |> normalize()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@stopwords, &1)))
    |> Enum.uniq()
  end

  @spec contains_token?(binary(), binary()) :: boolean()
  defp contains_token?(text, token), do: String.contains?(text, token)

  @spec add_region_boost(float(), atom() | nil) :: float()
  defp add_region_boost(score, region) when region in [:navigation, :hero, :search_form, :form],
    do: score + 0.25

  defp add_region_boost(score, _region), do: score

  @spec add_search_boost(float(), Candidate.t(), [binary()]) :: float()
  defp add_search_boost(score, candidate, goal_tokens) do
    searchable? =
      candidate
      |> candidate_text()
      |> normalize()
      |> then(&(String.contains?(&1, "search") or String.contains?(&1, "find")))

    if searchable? and goal_tokens != [], do: score + 0.3, else: score
  end

  @spec add_depth_penalty(float(), non_neg_integer()) :: float()
  defp add_depth_penalty(score, depth), do: score - depth * 0.05

  @spec add_boilerplate_penalty(float(), Candidate.t(), [binary()]) :: float()
  defp add_boilerplate_penalty(score, candidate, []) do
    text = normalize(candidate_text(candidate))

    if Enum.any?(@boilerplate, &String.contains?(text, &1)) do
      score - 0.4
    else
      score
    end
  end

  defp add_boilerplate_penalty(score, _candidate, _matches), do: score

  @spec reason(float(), [binary()], Candidate.t()) :: binary()
  defp reason(score, [], _candidate) when score <= 0.0, do: "low relevance fallback"
  defp reason(_score, [], candidate), do: "structural/navigation signal for #{candidate.url}"

  defp reason(_score, matches, _candidate) do
    "matched goal tokens: #{matches |> Enum.reverse() |> Enum.join(", ")}"
  end

  @spec append_reason(binary() | nil, binary()) :: binary()
  defp append_reason(nil, reason), do: reason
  defp append_reason(existing, reason), do: existing <> "; " <> reason

  @spec page_context_text(map()) :: binary()
  defp page_context_text(context) do
    page = context[:page]
    outline = context[:outline]

    [
      page && page.title,
      page && page.summary,
      outline && outline.text
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @spec candidate_text(Candidate.t()) :: binary()
  defp candidate_text(candidate), do: Enum.join([candidate.text, candidate.url], " ")

  @spec url_path_text(binary()) :: binary()
  defp url_path_text(url) do
    uri = URI.parse(url)
    Enum.join([uri.host, uri.path, uri.query], " ")
  end

  @spec url_pattern(binary()) :: binary()
  defp url_pattern(url) do
    uri = URI.parse(url)

    path =
      (uri.path || "/")
      |> String.split("/", trim: true)
      |> Enum.map(&pattern_segment/1)
      |> compact_path_pattern()

    "/" <> Enum.join(path, "/")
  end

  defp pattern_segment(segment) do
    cond do
      String.match?(segment, ~r/^\d+$/) -> ":id"
      String.match?(segment, ~r/^[a-z0-9-]{24,}$/i) -> ":slug"
      true -> segment
    end
  end

  defp compact_path_pattern(segments) when length(segments) > 2 do
    Enum.take(segments, 2) ++ [":..."]
  end

  defp compact_path_pattern(segments), do: segments

  @spec normalize(binary()) :: binary()
  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end
end
