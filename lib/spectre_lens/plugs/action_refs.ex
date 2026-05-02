defmodule SpectreLens.Plugs.ActionRefs do
  @moduledoc false

  alias SpectreLens.{ActionRef, Context, Plug}

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, _opts) do
    actions =
      []
      |> Kernel.++(interactive_actions(context.view.interactive))
      |> Kernel.++(form_actions(context.view.forms))
      |> Kernel.++(link_actions(context.view.links))
      |> Enum.with_index(1)
      |> Enum.map(fn {action, index} -> %{action | id: action.id || "a#{index}"} end)

    put_in(context.view.actions, actions)
  end

  @doc false
  @spec build_from_interactive([map()] | nil) :: [ActionRef.t()]
  def build_from_interactive(elements), do: interactive_actions(elements)

  @doc false
  @spec build_from_forms([map()] | nil) :: [ActionRef.t()]
  def build_from_forms(forms), do: form_actions(forms)

  @doc false
  @spec build_from_links([map()] | nil) :: [ActionRef.t()]
  def build_from_links(links), do: link_actions(links)

  @spec interactive_actions([map()] | nil) :: [ActionRef.t()]
  defp interactive_actions(elements) do
    Enum.map(elements || [], fn element ->
      tag = get(element, "tagName") || get(element, "tag") || ""
      role = get(element, "role")
      kind = kind_for(tag, role, get(element, "type"))
      name = get(element, "name") || get(element, "label")

      %ActionRef{
        id: nil,
        kind: kind,
        label: name,
        selector: selector_for(element),
        xpath: get(element, "xpath"),
        node_id: get(element, "nodeId") || get(element, "backendDOMNodeId"),
        href: get(element, "href"),
        role: role,
        name: name
      }
    end)
  end

  @spec form_actions([map()] | nil) :: [ActionRef.t()]
  defp form_actions(forms) do
    Enum.flat_map(forms || [], fn form ->
      form_action = %ActionRef{
        id: nil,
        kind: :form,
        label: get(form, "name") || get(form, "id") || "form",
        selector: get(form, "selector"),
        name: get(form, "name")
      }

      field_actions =
        form
        |> get("fields", [])
        |> Enum.map(&field_action/1)

      [form_action | field_actions]
    end)
  end

  @spec field_action(map()) :: ActionRef.t()
  defp field_action(field) do
    tag = get(field, "tag") || "input"

    %ActionRef{
      id: nil,
      kind: kind_for(tag, nil, get(field, "type")),
      label: get(field, "label") || get(field, "name") || get(field, "id"),
      selector: selector_for(field),
      name: get(field, "name")
    }
  end

  @spec link_actions([map()] | nil) :: [ActionRef.t()]
  defp link_actions(links) do
    Enum.map(links || [], fn link ->
      %ActionRef{
        id: nil,
        kind: :link,
        label: get(link, "text") || get(link, "href"),
        selector: selector_for(link),
        href: get(link, "href"),
        name: get(link, "text")
      }
    end)
  end

  @spec kind_for(binary(), binary() | nil, binary() | nil) :: ActionRef.kind()
  defp kind_for("a", _role, _type), do: :link
  defp kind_for("button", _role, _type), do: :button
  defp kind_for("select", _role, _type), do: :select
  defp kind_for("textarea", _role, _type), do: :textarea
  defp kind_for("input", _role, _type), do: :input
  defp kind_for(_tag, "button", _type), do: :button
  defp kind_for(_tag, "link", _type), do: :link
  defp kind_for(_tag, _role, "select"), do: :select
  defp kind_for(_tag, _role, _type), do: :custom

  @spec selector_for(map()) :: binary() | nil
  defp selector_for(map) do
    get(map, "selector") || id_selector(get(map, "id"))
  end

  @spec id_selector(binary() | nil) :: binary() | nil
  defp id_selector(nil), do: nil
  defp id_selector(""), do: nil
  defp id_selector(id), do: "##{id}"

  @spec get(map(), binary(), term()) :: term()
  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, known_atom_key(key), default)
  end

  @spec known_atom_key(binary()) :: atom() | nil
  defp known_atom_key("backendDOMNodeId"), do: :backendDOMNodeId
  defp known_atom_key("fields"), do: :fields
  defp known_atom_key("href"), do: :href
  defp known_atom_key("id"), do: :id
  defp known_atom_key("label"), do: :label
  defp known_atom_key("name"), do: :name
  defp known_atom_key("nodeId"), do: :nodeId
  defp known_atom_key("role"), do: :role
  defp known_atom_key("selector"), do: :selector
  defp known_atom_key("tag"), do: :tag
  defp known_atom_key("tagName"), do: :tagName
  defp known_atom_key("text"), do: :text
  defp known_atom_key("type"), do: :type
  defp known_atom_key("xpath"), do: :xpath
  defp known_atom_key(_key), do: nil
end
