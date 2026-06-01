defmodule SpectreLens.MapHelpers do
  @moduledoc """
  Safe access helpers for adapter maps.

  Browser adapters can return atom-keyed structs, JSON maps with string keys,
  or mixed maps. These helpers keep that boundary knowledge near the adapter
  layer instead of leaking string-key checks through the domain modules.
  """

  @doc "Fetches either an atom key or its known external string-key equivalent."
  @spec get(map(), atom() | binary(), term()) :: term()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  def get(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_atom_key(key), default)
  end

  def get(_map, _key, default), do: default

  @doc "Returns true for nil, empty, and whitespace-only strings."
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: false

  @doc "Returns true when an extracted interactive element is actually a link."
  @spec link?(map()) :: boolean()
  def link?(element) when is_map(element) do
    get(element, :tagName) == "a" or get(element, :tag) == "a" or
      get(element, :role) == "link" or not blank?(get(element, :href))
  end

  def link?(_element), do: false

  @doc "Maps known external string keys to existing atoms without creating atoms."
  @spec known_atom_key(binary()) :: atom() | nil
  def known_atom_key("backendDOMNodeId"), do: :backendDOMNodeId
  def known_atom_key("backendNodeId"), do: :backendNodeId
  def known_atom_key("fields"), do: :fields
  def known_atom_key("href"), do: :href
  def known_atom_key("id"), do: :id
  def known_atom_key("label"), do: :label
  def known_atom_key("name"), do: :name
  def known_atom_key("nodeId"), do: :nodeId
  def known_atom_key("role"), do: :role
  def known_atom_key("selector"), do: :selector
  def known_atom_key("tag"), do: :tag
  def known_atom_key("tagName"), do: :tagName
  def known_atom_key("text"), do: :text
  def known_atom_key("type"), do: :type
  def known_atom_key("xpath"), do: :xpath
  def known_atom_key(_key), do: nil
end
