defmodule SpectreLens.Plugs.Forms do
  @moduledoc """
  Adds form metadata to a view when `:forms` is requested.

  Form extraction stays in the browser adapter; this plug only decides whether
  the projection belongs in the current look pipeline.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @form_keys [
    "action",
    "fields",
    "id",
    "index",
    "method",
    "name",
    "selector",
    :action,
    :fields,
    :id,
    :index,
    :method,
    :name,
    :selector
  ]
  @field_keys [
    "disabled",
    "id",
    "index",
    "label",
    "name",
    "options",
    "required",
    "selector",
    "tag",
    "type",
    :disabled,
    :id,
    :index,
    :label,
    :name,
    :options,
    :required,
    :selector,
    :tag,
    :type
  ]
  @option_keys ["text", :text]

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :forms) do
      Helpers.collect(context, :forms, fn ->
        with {:ok, forms} <- SpectreLens.Protocol.forms(context.tab, opts) do
          {:ok, sanitize(forms)}
        end
      end)
    else
      context
    end
  end

  @doc false
  @spec sanitize(term()) :: [map()]
  def sanitize(forms) when is_list(forms) do
    forms
    |> Enum.filter(&is_map/1)
    |> Enum.map(&sanitize_form/1)
  end

  def sanitize(_forms), do: []

  @spec sanitize_form(map()) :: map()
  defp sanitize_form(form) do
    form
    |> Map.take(@form_keys)
    |> sanitize_action()
    |> update_if_present("fields", &sanitize_fields/1)
    |> update_if_present(:fields, &sanitize_fields/1)
  end

  @spec sanitize_action(map()) :: map()
  defp sanitize_action(form) do
    Enum.reduce(["action", :action], form, fn key, acc ->
      case Map.get(acc, key) do
        action when is_binary(action) -> Map.put(acc, key, SpectreLens.URLPolicy.sanitize(action))
        _ -> acc
      end
    end)
  end

  @spec sanitize_fields(term()) :: [map()]
  defp sanitize_fields(fields) when is_list(fields) do
    fields
    |> Enum.filter(&(is_map(&1) and not hidden?(&1)))
    |> Enum.map(fn field ->
      field
      |> Map.take(@field_keys)
      |> update_if_present("options", &sanitize_options/1)
      |> update_if_present(:options, &sanitize_options/1)
    end)
  end

  defp sanitize_fields(_fields), do: []

  @spec sanitize_options(term()) :: [map()]
  defp sanitize_options(options) when is_list(options) do
    options
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.take(&1, @option_keys))
  end

  defp sanitize_options(_options), do: []

  @spec hidden?(map()) :: boolean()
  defp hidden?(field) do
    type = Map.get(field, "type", Map.get(field, :type))
    type == :hidden or (is_binary(type) and String.downcase(type) == "hidden")
  end

  @spec update_if_present(map(), term(), (term() -> term())) :: map()
  defp update_if_present(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end
end
