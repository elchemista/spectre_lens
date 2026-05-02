defmodule SpectreLens.Plugs.ActionRefs do
  @moduledoc false

  alias SpectreLens.{ActionRef, Context, MapHelpers, Plug}

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
      tag = MapHelpers.get(element, :tagName) || MapHelpers.get(element, :tag) || ""
      role = MapHelpers.get(element, :role)
      kind = kind_for(tag, role, MapHelpers.get(element, :type))
      name = MapHelpers.get(element, :name) || MapHelpers.get(element, :label)

      %ActionRef{
        id: nil,
        kind: kind,
        label: name,
        selector: selector_for(element),
        xpath: MapHelpers.get(element, :xpath),
        node_id: MapHelpers.get(element, :nodeId) || MapHelpers.get(element, :backendDOMNodeId),
        href: MapHelpers.get(element, :href),
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
        label: MapHelpers.get(form, :name) || MapHelpers.get(form, :id) || "form",
        selector: MapHelpers.get(form, :selector),
        name: MapHelpers.get(form, :name)
      }

      field_actions =
        form
        |> MapHelpers.get(:fields, [])
        |> Enum.map(&field_action/1)

      [form_action | field_actions]
    end)
  end

  @spec field_action(map()) :: ActionRef.t()
  defp field_action(field) do
    tag = MapHelpers.get(field, :tag) || "input"

    %ActionRef{
      id: nil,
      kind: kind_for(tag, nil, MapHelpers.get(field, :type)),
      label:
        MapHelpers.get(field, :label) || MapHelpers.get(field, :name) ||
          MapHelpers.get(field, :id),
      selector: selector_for(field),
      name: MapHelpers.get(field, :name)
    }
  end

  @spec link_actions([map()] | nil) :: [ActionRef.t()]
  defp link_actions(links) do
    Enum.map(links || [], fn link ->
      %ActionRef{
        id: nil,
        kind: :link,
        label: MapHelpers.get(link, :text) || MapHelpers.get(link, :href),
        selector: selector_for(link),
        href: MapHelpers.get(link, :href),
        name: MapHelpers.get(link, :text)
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
    MapHelpers.get(map, :selector) || id_selector(MapHelpers.get(map, :id))
  end

  @spec id_selector(binary() | nil) :: binary() | nil
  defp id_selector(nil), do: nil
  defp id_selector(""), do: nil
  defp id_selector(id), do: "##{id}"
end
