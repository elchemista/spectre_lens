defmodule SpectreLens.Outline do
  @moduledoc """
  Compact outline of page sections for quick agent orientation.

  `text` is the human/agent-readable outline. `sections` keeps lightweight
  handles that can be passed back to `SpectreLens.zoom_in/3`.
  """

  alias SpectreLens.{MapHelpers, Region}
  alias SpectreLens.Outline.Section

  @type t :: %__MODULE__{
          text: binary(),
          sections: [Section.t()],
          detailed?: boolean()
        }

  defstruct text: "", sections: [], detailed?: false

  @doc "Builds an outline from page-map regions."
  @spec from_regions([Region.t()], keyword()) :: t()
  def from_regions(regions, opts) do
    detailed? = detailed?(opts)

    sections =
      regions
      |> Enum.filter(&outline_section?/1)
      |> sort_sections()
      |> Enum.map(&section_from_region/1)

    %__MODULE__{
      text: render(sections, detailed?),
      sections: sections,
      detailed?: detailed?
    }
  end

  @doc "Returns page-map options suitable for outline generation."
  @spec page_map_opts(keyword()) :: keyword()
  def page_map_opts(opts) do
    opts
    |> Keyword.put_new(:max_regions, 24)
    |> Keyword.delete(:url)
  end

  @spec detailed?(keyword()) :: boolean()
  defp detailed?(opts), do: opts[:detailed] || opts[:detailed?] || :detailed in opts

  @spec outline_section?(Region.t()) :: boolean()
  defp outline_section?(%Region{purpose: :content_section, label: nil}), do: false
  defp outline_section?(_region), do: true

  @spec sort_sections([Region.t()]) :: [Region.t()]
  defp sort_sections(regions) do
    regions
    |> Enum.with_index()
    |> Enum.sort_by(fn {region, index} -> {section_sort_bucket(region), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec section_sort_bucket(Region.t()) :: integer()
  defp section_sort_bucket(%Region{purpose: :navigation}), do: 0
  defp section_sort_bucket(%Region{kind: :banner}), do: 0
  defp section_sort_bucket(%Region{purpose: :hero}), do: 1
  defp section_sort_bucket(%Region{purpose: :footer}), do: 9
  defp section_sort_bucket(%Region{kind: :contentinfo}), do: 9
  defp section_sort_bucket(_region), do: 5

  @spec section_from_region(Region.t()) :: Section.t()
  defp section_from_region(%Region{} = region) do
    %Section{
      id: region.id,
      title: section_title(region.purpose, region.label),
      purpose: region.purpose,
      selector: region.selector,
      label: region.label,
      text: trim_text(region.text, 220),
      links: label_list(region.links, [:text, :href], 6),
      fields: label_list(region.fields, [:label, :name, :type], 8),
      stats: compact_stats(region.stats)
    }
  end

  @spec render([Section.t()], boolean()) :: binary()
  defp render(sections, false) do
    Enum.map_join(sections, "\n", &"[#{&1.title}]")
  end

  defp render(sections, true), do: Enum.map_join(sections, "\n\n", &render_detailed_section/1)

  @spec render_detailed_section(Section.t()) :: binary()
  defp render_detailed_section(%Section{} = section) do
    [
      "[ #{section.title} ]",
      section.selector && detail_line("Selector", section.selector),
      section.label && detail_line("Label", section.label),
      section.label && detail_line("Heading", section.label),
      section.text && detail_line("Text", section.text),
      labels_line("Links", section.links),
      labels_line("Fields", section.fields),
      stats_line(section.stats),
      "[end #{section.title}]"
    ]
    |> Enum.reject(&MapHelpers.blank?/1)
    |> Enum.join("\n")
  end

  @spec section_title(Region.purpose(), binary() | nil) :: binary()
  defp section_title(purpose, label) do
    base =
      purpose
      |> to_string()
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

    cond do
      MapHelpers.blank?(label) -> base
      String.contains?(String.downcase(base), String.downcase(label)) -> base
      true -> "#{base} / #{String.slice(label, 0, 60)}"
    end
  end

  @spec trim_text(binary() | nil, pos_integer()) :: binary() | nil
  defp trim_text(text, max) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp trim_text(_text, _max), do: nil

  @spec label_list([map()], [atom()], pos_integer()) :: [binary()]
  defp label_list(items, keys, limit) do
    items
    |> Enum.map(&first_label(&1, keys))
    |> Enum.reject(&MapHelpers.blank?/1)
    |> Enum.take(limit)
  end

  @spec first_label(map(), [atom()]) :: binary() | nil
  defp first_label(map, keys) do
    Enum.find_value(keys, &MapHelpers.get(map, &1))
  end

  @spec compact_stats(map()) :: map()
  defp compact_stats(stats) when is_map(stats) do
    [:links, :buttons, :fields, :images]
    |> Enum.reduce(%{}, fn key, acc ->
      case MapHelpers.get(stats, key, 0) do
        count when is_integer(count) and count > 0 -> Map.put(acc, key, count)
        _ -> acc
      end
    end)
  end

  defp compact_stats(_stats), do: %{}

  @spec labels_line(binary(), [binary()]) :: binary() | nil
  defp labels_line(_title, []), do: nil
  defp labels_line(title, labels), do: detail_line(title, Enum.join(labels, " | "))

  @spec stats_line(map()) :: binary() | nil
  defp stats_line(stats) do
    parts =
      [
        stat_part(stats, :links, "links"),
        stat_part(stats, :buttons, "buttons"),
        stat_part(stats, :fields, "fields"),
        stat_part(stats, :images, "images")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: detail_line("Contains", Enum.join(parts, ", "))
  end

  @spec stat_part(map(), atom(), binary()) :: binary() | nil
  defp stat_part(stats, key, label) do
    case Map.get(stats, key) do
      count when is_integer(count) and count > 0 -> "#{count} #{label}"
      _ -> nil
    end
  end

  @spec detail_line(binary(), binary()) :: binary()
  defp detail_line(title, value), do: "  [ #{title}: #{value} ]"
end

defimpl String.Chars, for: SpectreLens.Outline do
  def to_string(outline), do: outline.text
end
