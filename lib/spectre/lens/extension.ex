defmodule Spectre.Lens.Extension do
  @moduledoc false

  @spec id() :: :lens
  def id, do: :lens

  @spec api_version() :: 1
  def api_version, do: 1

  @spec compile(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(_owner, opts) do
    case Keyword.fetch(opts, :stack_config) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, invalid} -> {:error, {:invalid_lens_stack_config, invalid}}
      :error -> {:ok, %{options: opts, backend: nil, policy: nil}}
    end
  end

  @spec agent_config(map()) :: keyword()
  def agent_config(config) when is_map(config), do: [lens: config]

  @spec action_providers(map()) :: [tuple()]
  def action_providers(config) when is_map(config) do
    [{:lens, Spectre.Lens.ActionProvider, config: config}]
  end
end
