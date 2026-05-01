defmodule SpectreLens.LlmsTxt do
  @moduledoc """
  Discovery and parsing for `llms.txt` agent context files.

  `llms.txt` is a Markdown entry point that websites can expose for agents.
  Spectre Lens treats it as a first-class context source alongside rendered
  page views: fetch the index, optionally fetch a full context document, and
  return structured links plus raw Markdown.
  """

  alias SpectreLens.Telemetry

  defstruct [
    :url,
    :full_url,
    :base_url,
    :title,
    :summary,
    :info,
    :content,
    :full_content,
    sections: [],
    links: [],
    warnings: []
  ]

  @llms_names ["llms.txt"]
  @full_names ["llms-full.txt", "llms-ctx-full.txt"]
  @default_timeout 15_000
  @default_max_bytes 5_000_000

  @type link :: %{
          title: binary(),
          url: binary(),
          notes: binary() | nil,
          section: binary() | nil,
          optional?: boolean()
        }

  @type section :: %{
          title: binary(),
          raw: binary(),
          links: [link()],
          optional?: boolean()
        }

  @type t :: %__MODULE__{
          url: binary() | nil,
          full_url: binary() | nil,
          base_url: binary(),
          title: binary() | nil,
          summary: binary() | nil,
          info: binary() | nil,
          content: binary() | nil,
          full_content: binary() | nil,
          sections: [section()],
          links: [link()],
          warnings: [term()]
        }

  @type fetch_result :: {:ok, binary()} | {:error, term()}
  @type fetcher :: (binary(), keyword() -> fetch_result())
  @type page_link :: %{optional(binary()) => term()} | %{optional(atom()) => term()}

  @doc """
  Discovers and fetches `llms.txt` for a site or direct agent-file URL.

  Options:
    * `:full?` - also fetch `llms-full.txt` / `llms-ctx-full.txt`, default `false`
    * `:timeout` - HTTP timeout in milliseconds
    * `:max_bytes` - maximum accepted response body size
    * `:fetcher` - custom function `(url, opts -> {:ok, body} | {:error, reason})`
  """
  @spec discover(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def discover(url, opts \\ []) when is_binary(url) do
    Telemetry.span([:spectre_lens, :agent, :llms], %{url: url}, fn ->
      result = do_discover(url, opts)
      {result, %{result: result}}
    end)
  end

  @doc """
  Discovers `llms.txt` from page metadata and HTTP `Link` headers.

  `page_links` should contain maps extracted from `<link>` or `<meta>` tags.
  When metadata is absent, Spectre Lens checks the current page's HTTP `Link`
  header for entries pointing to `llms.txt` or `llms-full.txt`.
  """
  @spec discover_from_page(binary(), [page_link()], keyword()) :: {:ok, t()} | {:error, term()}
  def discover_from_page(page_url, page_links, opts \\ [])
      when is_binary(page_url) and is_list(page_links) do
    Telemetry.span([:spectre_lens, :agent, :llms], %{url: page_url, source: :page}, fn ->
      result = do_discover_from_page(page_url, page_links, opts)
      {result, %{result: result}}
    end)
  end

  @doc "Parses an `llms.txt` Markdown document into structured agent context."
  @spec parse(binary(), keyword()) :: t()
  def parse(content, opts \\ []) when is_binary(content) do
    base_url = opts[:base_url] || opts[:url] || ""
    source_url = opts[:url]
    lines = String.split(content, ~r/\R/)
    {title, rest} = take_title(lines)
    {summary, rest} = take_summary(drop_blank(rest))
    {info, section_lines} = take_info(drop_blank(rest))
    sections = parse_sections(section_lines, base_url)

    %__MODULE__{
      url: source_url,
      base_url: base_url,
      title: title,
      summary: summary,
      info: info,
      content: content,
      sections: sections,
      links: Enum.flat_map(sections, & &1.links)
    }
  end

  @doc "Returns Markdown context to feed an agent from a parsed `llms.txt` document."
  @spec to_context(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def to_context(%__MODULE__{} = doc, opts \\ []) do
    case opts[:prefer] || :full do
      :full -> preferred_context(doc.full_content, doc.content)
      :index -> preferred_context(doc.content, nil)
      :both -> both_context(doc)
      other -> {:error, {:invalid_llms_context_preference, other}}
    end
  end

  @doc "Returns candidate index and full-context URLs for a site or direct file URL."
  @spec candidate_urls(binary()) :: %{index: [binary()], full: [binary()]}
  def candidate_urls(url) when is_binary(url) do
    uri = URI.parse(url)

    if direct_agent_file?(uri.path || "") do
      direct_candidates(uri)
    else
      base_candidates(uri)
    end
  end

  @spec do_discover(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  defp do_discover(url, opts) do
    candidates = candidate_urls(url)

    case fetch_first(candidates.index, opts) do
      {:ok, {source_url, content}} ->
        doc =
          content
          |> parse(url: source_url, base_url: source_url)
          |> maybe_fetch_full(candidates.full, opts)

        {:ok, doc}

      {:error, reason} ->
        {:error, {:llms_txt_not_found, reason, candidates.index}}
    end
  end

  @spec do_discover_from_page(binary(), [page_link()], keyword()) :: {:ok, t()} | {:error, term()}
  defp do_discover_from_page(page_url, page_links, opts) do
    candidates =
      page_url
      |> metadata_candidates(page_links)
      |> Kernel.++(header_candidates(page_url, opts))
      |> Enum.uniq()

    case candidates do
      [] -> {:error, {:llms_txt_not_found, :no_page_metadata_or_header, []}}
      urls -> discover_first(urls, opts)
    end
  end

  @spec discover_first([binary()], keyword()) :: {:ok, t()} | {:error, term()}
  defp discover_first(urls, opts) do
    Enum.reduce_while(urls, {:error, :no_candidates}, fn url, _last_error ->
      case do_discover(url, opts) do
        {:ok, doc} -> {:halt, {:ok, doc}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, {:llms_txt_not_found, reason, urls}}
      other -> other
    end
  end

  @spec maybe_fetch_full(t(), [binary()], keyword()) :: t()
  defp maybe_fetch_full(doc, candidates, opts) do
    if Keyword.get(opts, :full?, false) do
      fetch_full(doc, candidates, opts)
    else
      doc
    end
  end

  @spec fetch_full(t(), [binary()], keyword()) :: t()
  defp fetch_full(doc, candidates, opts) do
    case fetch_first(candidates, opts) do
      {:ok, {full_url, full_content}} ->
        %{doc | full_url: full_url, full_content: full_content}

      {:error, reason} ->
        %{doc | warnings: [{:llms_full_not_found, reason, candidates} | doc.warnings]}
    end
  end

  @spec fetch_first([binary()], keyword()) :: {:ok, {binary(), binary()}} | {:error, term()}
  defp fetch_first(urls, opts) do
    Enum.reduce_while(urls, {:error, :no_candidates}, fn url, _last_error ->
      case fetch(url, opts) do
        {:ok, body} -> {:halt, {:ok, {url, body}}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  @spec fetch(binary(), keyword()) :: fetch_result()
  defp fetch(url, opts) do
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/2)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, body} <- fetcher.(url, opts) do
      validate_body(body, max_bytes)
    end
  end

  @spec default_fetch(binary(), keyword()) :: fetch_result()
  defp default_fetch(url, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Req.get(url, retry: false, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body_to_binary(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec metadata_candidates(binary(), [page_link()]) :: [binary()]
  defp metadata_candidates(page_url, page_links) do
    page_links
    |> Enum.flat_map(&metadata_href/1)
    |> Enum.filter(&llms_url?/1)
    |> Enum.map(&resolve_url(page_url, &1))
  end

  @spec metadata_href(page_link()) :: [binary()]
  defp metadata_href(link) when is_map(link) do
    ["href", :href, "content", :content]
    |> Enum.map(&Map.get(link, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  @spec header_candidates(binary(), keyword()) :: [binary()]
  defp header_candidates(page_url, opts) do
    if Keyword.get(opts, :llms_headers?, true) do
      page_url
      |> fetch_link_header(opts)
      |> parse_link_header(page_url)
    else
      []
    end
  end

  @spec fetch_link_header(binary(), keyword()) :: binary() | nil
  defp fetch_link_header(page_url, opts) do
    header_fetcher = Keyword.get(opts, :header_fetcher, &default_header_fetch/2)

    with {:ok, headers} <- header_fetcher.(page_url, opts) do
      get_header(headers, "link")
    end
  end

  @spec default_header_fetch(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  defp default_header_fetch(page_url, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Req.request(method: :head, url: page_url, retry: false, receive_timeout: timeout) do
      {:ok, %{status: status, headers: headers}} when status in 200..399 -> {:ok, headers}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_header(term(), binary()) :: binary() | nil
  defp get_header(headers, name) when is_map(headers) do
    headers
    |> Map.get(name, Map.get(headers, String.downcase(name)))
    |> header_value()
  end

  defp get_header(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: value
    end)
    |> header_value()
  end

  defp get_header(_headers, _name), do: nil

  @spec header_value(term()) :: binary() | nil
  defp header_value(nil), do: nil
  defp header_value(values) when is_list(values), do: Enum.join(values, ", ")
  defp header_value(value) when is_binary(value), do: value
  defp header_value(value), do: to_string(value)

  @spec parse_link_header(binary() | nil, binary()) :: [binary()]
  defp parse_link_header(nil, _page_url), do: []

  defp parse_link_header(header, page_url) do
    ~r/<([^>]+)>\s*;\s*rel="?([^";,]+)"?/i
    |> Regex.scan(header)
    |> Enum.filter(fn [_, href, rel] -> llms_url?(href) or llms_rel?(rel) end)
    |> Enum.map(fn [_, href, _rel] -> resolve_url(page_url, href) end)
  end

  @spec llms_url?(binary()) :: boolean()
  defp llms_url?(value) do
    value = String.downcase(value)
    Enum.any?(@llms_names ++ @full_names, &String.contains?(value, &1))
  end

  @spec llms_rel?(binary()) :: boolean()
  defp llms_rel?(rel), do: rel |> String.downcase() |> String.contains?("llms")

  @spec validate_body(binary(), non_neg_integer()) :: fetch_result()
  defp validate_body(body, max_bytes) when byte_size(body) <= max_bytes, do: {:ok, body}
  defp validate_body(_body, max_bytes), do: {:error, {:body_too_large, max_bytes}}

  @spec body_to_binary(binary() | term()) :: binary()
  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(body), do: inspect(body)

  @spec take_title([binary()]) :: {binary() | nil, [binary()]}
  defp take_title(["# " <> title | rest]), do: {String.trim(title), rest}
  defp take_title(lines), do: {nil, lines}

  @spec take_summary([binary()]) :: {binary() | nil, [binary()]}
  defp take_summary(lines) do
    {summary_lines, rest} = Enum.split_while(lines, &blockquote?/1)
    summary = summary_lines |> Enum.map(&clean_blockquote/1) |> compact_join("\n")
    {empty_to_nil(summary), rest}
  end

  @spec take_info([binary()]) :: {binary() | nil, [binary()]}
  defp take_info(lines) do
    {info_lines, rest} = Enum.split_while(lines, &(not section_heading?(&1)))
    {empty_to_nil(compact_join(info_lines, "\n")), rest}
  end

  @spec parse_sections([binary()], binary()) :: [section()]
  defp parse_sections(lines, base_url) do
    {sections, current} =
      Enum.reduce(lines, {[], nil}, fn line, {sections, current} ->
        if section_heading?(line) do
          {close_section(sections, current, base_url), new_section(line)}
        else
          {sections, append_section_line(current, line)}
        end
      end)

    sections
    |> close_section(current, base_url)
    |> Enum.reverse()
  end

  @spec close_section([section()], map() | nil, binary()) :: [section()]
  defp close_section(sections, nil, _base_url), do: sections

  defp close_section(sections, current, base_url) do
    raw = compact_join(Enum.reverse(current.raw_lines), "\n")
    links = raw |> String.split("\n") |> parse_links(base_url, current.title, current.optional?)
    section = %{title: current.title, raw: raw, links: links, optional?: current.optional?}
    [section | sections]
  end

  @spec new_section(binary()) :: map()
  defp new_section("## " <> title) do
    title = String.trim(title)
    %{title: title, raw_lines: [], optional?: optional_section?(title)}
  end

  @spec append_section_line(map() | nil, binary()) :: map() | nil
  defp append_section_line(nil, _line), do: nil
  defp append_section_line(current, line), do: %{current | raw_lines: [line | current.raw_lines]}

  @spec parse_links([binary()], binary(), binary(), boolean()) :: [link()]
  defp parse_links(lines, base_url, section, optional?) do
    lines
    |> Enum.map(&parse_link(&1, base_url, section, optional?))
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_link(binary(), binary(), binary(), boolean()) :: link() | nil
  defp parse_link(line, base_url, section, optional?) do
    case Regex.run(~r/^\s*[-*]\s+\[([^\]]+)\]\(([^)]+)\)(?::\s*(.*))?\s*$/, line) do
      [_, title, href] ->
        link(title, href, nil, base_url, section, optional?)

      [_, title, href, notes] ->
        link(title, href, notes, base_url, section, optional?)

      _ ->
        nil
    end
  end

  @spec link(binary(), binary(), binary() | nil, binary(), binary(), boolean()) :: link()
  defp link(title, href, notes, base_url, section, optional?) do
    %{
      title: String.trim(title),
      url: resolve_url(base_url, href),
      notes: empty_to_nil(notes),
      section: section,
      optional?: optional?
    }
  end

  @spec resolve_url(binary(), binary()) :: binary()
  defp resolve_url("", href), do: href

  defp resolve_url(base_url, href) do
    base_url
    |> URI.parse()
    |> URI.merge(href)
    |> URI.to_string()
  rescue
    _ -> href
  end

  @spec preferred_context(binary() | nil, binary() | nil) :: {:ok, binary()} | {:error, term()}
  defp preferred_context(nil, nil), do: {:error, :no_llms_context}
  defp preferred_context(content, _fallback) when is_binary(content), do: {:ok, content}
  defp preferred_context(nil, fallback), do: {:ok, fallback}

  @spec both_context(t()) :: {:ok, binary()} | {:error, term()}
  defp both_context(%__MODULE__{content: nil, full_content: nil}), do: {:error, :no_llms_context}
  defp both_context(%__MODULE__{content: content, full_content: nil}), do: {:ok, content}

  defp both_context(%__MODULE__{content: nil, full_content: full_content}),
    do: {:ok, full_content}

  defp both_context(%__MODULE__{content: content, full_content: full_content}) do
    {:ok, content <> "\n\n---\n\n" <> full_content}
  end

  @spec direct_agent_file?(binary()) :: boolean()
  defp direct_agent_file?(path) do
    name = path |> Path.basename() |> String.downcase()
    name in @llms_names or name in @full_names
  end

  @spec direct_candidates(URI.t()) :: %{index: [binary()], full: [binary()]}
  defp direct_candidates(uri) do
    url = URI.to_string(uri)
    name = uri.path |> Path.basename() |> String.downcase()

    if name in @full_names do
      %{index: [url], full: [url]}
    else
      %{index: [url], full: sibling_urls(uri, @full_names)}
    end
  end

  @spec base_candidates(URI.t()) :: %{index: [binary()], full: [binary()]}
  defp base_candidates(uri) do
    bases = candidate_bases(uri)
    %{index: file_candidates(bases, @llms_names), full: file_candidates(bases, @full_names)}
  end

  @spec candidate_bases(URI.t()) :: [URI.t()]
  defp candidate_bases(uri) do
    origin = %{uri | path: "/", query: nil, fragment: nil}
    local = %{uri | path: directory_path(uri.path || "/"), query: nil, fragment: nil}
    Enum.uniq_by([local, origin], &URI.to_string/1)
  end

  @spec sibling_urls(URI.t(), [binary()]) :: [binary()]
  defp sibling_urls(uri, names) do
    base = %{uri | path: directory_path(uri.path || "/"), query: nil, fragment: nil}
    file_candidates([base], names)
  end

  @spec file_candidates([URI.t()], [binary()]) :: [binary()]
  defp file_candidates(bases, names) do
    for base <- bases, name <- names do
      %{base | path: join_path(base.path || "/", name)}
      |> URI.to_string()
    end
  end

  @spec directory_path(binary()) :: binary()
  defp directory_path(""), do: "/"
  defp directory_path("/"), do: "/"

  defp directory_path(path) do
    cond do
      String.ends_with?(path, "/") -> path
      path_has_extension?(path) -> path |> Path.dirname() |> ensure_slash()
      true -> ensure_slash(path)
    end
  end

  @spec join_path(binary(), binary()) :: binary()
  defp join_path(path, name), do: path |> ensure_slash() |> Kernel.<>(name)

  @spec ensure_slash(binary()) :: binary()
  defp ensure_slash(path), do: if(String.ends_with?(path, "/"), do: path, else: path <> "/")

  @spec path_has_extension?(binary()) :: boolean()
  defp path_has_extension?(path) do
    path
    |> Path.basename()
    |> String.contains?(".")
  end

  @spec section_heading?(binary()) :: boolean()
  defp section_heading?("## " <> _), do: true
  defp section_heading?(_line), do: false

  @spec blockquote?(binary()) :: boolean()
  defp blockquote?("> " <> _), do: true
  defp blockquote?(">" <> _), do: true
  defp blockquote?(_line), do: false

  @spec clean_blockquote(binary()) :: binary()
  defp clean_blockquote(">" <> line), do: String.trim(line)

  @spec optional_section?(binary()) :: boolean()
  defp optional_section?(title), do: String.downcase(title) == "optional"

  @spec drop_blank([binary()]) :: [binary()]
  defp drop_blank(lines), do: Enum.drop_while(lines, &(String.trim(&1) == ""))

  @spec compact_join([binary()], binary()) :: binary()
  defp compact_join(lines, joiner) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(joiner)
  end

  @spec empty_to_nil(binary() | nil) :: binary() | nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
