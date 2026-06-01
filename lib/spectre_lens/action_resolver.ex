defmodule SpectreLens.ActionResolver do
  @moduledoc """
  Resolves agent-friendly action inputs into protocol-ready targets.

  Public actions can be addressed by raw selectors, `%SpectreLens.ActionRef{}`
  structs, link maps, or text queries such as `text: "Sign in"`. This module
  keeps that boundary translation out of `SpectreLens` so the facade can stay
  focused on orchestration and error wrapping.

  ## Examples

      iex> alias SpectreLens.ActionResolver
      iex> ActionResolver.navigation_url(%SpectreLens.Tab{}, "https://example.com", [])
      {:ok, "https://example.com"}

      iex> ActionResolver.navigation_url(%SpectreLens.Tab{}, %{"href" => "/docs"}, [])
      {:ok, "/docs"}
  """

  alias SpectreLens.{ActionRef, ElementNotFoundError, MapHelpers, Tab}

  @typedoc "A selector, action reference, link map, or keyword text query."
  @type action_query :: binary() | ActionRef.t() | map() | keyword()

  @doc """
  Resolves a navigation action into a URL.

  Text queries are matched against the current page's links through the active
  browser protocol. Raw binaries and link-like maps are returned without a page
  lookup.
  """
  @spec navigation_url(Tab.t(), action_query(), keyword()) :: {:ok, binary()} | {:error, term()}
  def navigation_url(_tab, url, _opts) when is_binary(url), do: {:ok, url}

  def navigation_url(_tab, %ActionRef{kind: :link, href: url}, _opts) when is_binary(url),
    do: {:ok, url}

  def navigation_url(_tab, %{"href" => href}, _opts) when is_binary(href), do: {:ok, href}
  def navigation_url(_tab, %{href: href}, _opts) when is_binary(href), do: {:ok, href}

  def navigation_url(%Tab{} = tab, query, opts) when is_list(query) do
    with {:ok, link} <- matching_link(tab, query, opts),
         href when is_binary(href) <- MapHelpers.get(link, :href) do
      {:ok, href}
    else
      _ -> {:error, ElementNotFoundError.new(query)}
    end
  end

  def navigation_url(_tab, other, _opts), do: {:error, {:missing_navigation_url, other}}

  @doc """
  Resolves a click action into the best target understood by the browser driver.

  The resolution order is deliberately explicit:

    * `:ref` means the caller already chose the target
    * `:href` searches links only
    * text/name/label/title queries prefer controls and fall back to links
  """
  @spec clickable_ref(Tab.t(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  def clickable_ref(%Tab{} = tab, opts, call_opts) do
    cond do
      Keyword.has_key?(opts, :ref) ->
        {:ok, opts[:ref]}

      Keyword.has_key?(opts, :href) ->
        matching_link(tab, opts, call_opts)

      text_query?(opts) ->
        matching_click_target(tab, opts, call_opts)

      true ->
        {:error, ElementNotFoundError.new(opts)}
    end
  end

  @spec matching_click_target(Tab.t(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp matching_click_target(tab, query, opts) do
    case matching_interactive(tab, query, opts) do
      {:ok, target} -> {:ok, target}
      {:error, _} -> matching_link(tab, query, opts)
    end
  end

  @spec matching_link(Tab.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  defp matching_link(tab, query, opts) do
    with {:ok, links} <- SpectreLens.Protocol.links(tab, opts) do
      best_match(links, query, [:text, :title, :href])
    end
  end

  @spec matching_interactive(Tab.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  defp matching_interactive(tab, query, opts) do
    with {:ok, elements} <- SpectreLens.Protocol.interactive_elements(tab, opts) do
      elements
      |> Enum.reject(&MapHelpers.link?/1)
      |> best_match(query, [:name, :label, :text, :title])
    end
  end

  @spec best_match([map()], keyword(), [atom()]) :: {:ok, map()} | {:error, term()}
  defp best_match(candidates, query, keys) do
    query_text = query_text(query)

    candidates
    |> Enum.map(&{match_score(query_text, &1, keys), &1})
    |> Enum.max_by(&elem(&1, 0), fn -> {0.0, nil} end)
    |> case do
      {score, candidate} when score >= 0.62 and is_map(candidate) -> {:ok, candidate}
      _ -> {:error, ElementNotFoundError.new(query)}
    end
  end

  @spec text_query?(keyword()) :: boolean()
  defp text_query?(opts), do: not MapHelpers.blank?(query_text(opts))

  @spec query_text(keyword()) :: binary()
  defp query_text(opts) do
    opts[:text] || opts[:name] || opts[:label] || opts[:title] || opts[:href] || ""
  end

  @spec match_score(binary(), map(), [atom()]) :: float()
  defp match_score(query, candidate, keys) do
    query = normalize_match_text(query)

    keys
    |> Enum.map(&(candidate |> MapHelpers.get(&1, "") |> score_text(query)))
    |> Enum.max(fn -> 0.0 end)
  end

  @spec score_text(term(), binary()) :: float()
  defp score_text(_candidate, ""), do: 0.0

  defp score_text(candidate, query) when is_binary(candidate) do
    candidate = normalize_match_text(candidate)

    cond do
      candidate == "" -> 0.0
      candidate == query -> 1.0
      String.contains?(candidate, query) -> 0.92
      String.contains?(query, candidate) -> 0.82
      true -> String.jaro_distance(candidate, query)
    end
  end

  defp score_text(_candidate, _query), do: 0.0

  @spec normalize_match_text(binary()) :: binary()
  defp normalize_match_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end
end
