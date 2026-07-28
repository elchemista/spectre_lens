defmodule Spectre.Lens.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl true
  def id, do: :lens

  @impl true
  def api_version, do: 1

  @impl true
  def compile(_owner, opts) do
    case Keyword.fetch(opts, :stack_config) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, invalid} -> {:error, {:invalid_lens_stack_config, invalid}}
      :error -> {:ok, %{options: opts, backend: nil, policy: nil}}
    end
  end

  @impl true
  def agent_config(config) when is_map(config), do: [lens: config]

  @impl true
  def action_providers(config) when is_map(config) do
    [{:lens, Spectre.Lens.ActionProvider, config: config}]
  end
end
