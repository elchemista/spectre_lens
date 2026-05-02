defmodule SpectreLens.Plugs.Interactive do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :interactive) do
      Helpers.collect(context, :interactive, fn ->
        with {:ok, elements} <- SpectreLens.Protocol.interactive_elements(context.tab, opts) do
          {:ok, Enum.reject(elements, &link?/1)}
        end
      end)
    else
      context
    end
  end

  @spec link?(map()) :: boolean()
  defp link?(element) when is_map(element) do
    Map.get(element, "tagName") == "a" or Map.get(element, "tag") == "a" or
      Map.get(element, "role") == "link" or Map.has_key?(element, "href")
  end

  defp link?(_element), do: false
end
