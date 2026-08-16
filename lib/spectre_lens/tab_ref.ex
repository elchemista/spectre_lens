defmodule SpectreLens.TabRef do
  @moduledoc """
  Portable logical reference to a live Lens tab.

  A `%SpectreLens.Tab{}` contains connection, runtime, and request-guard
  processes and must never cross a durable Spectre State or Run boundary.
  `TabRef` contains only logical target identity. Resolve it against the
  caller-owned runtime with `SpectreLens.resolve_tab/2` immediately before an
  operation.
  """

  alias SpectreLens.Tab

  @version 1

  @enforce_keys [:id, :instance_id]
  defstruct version: @version,
            id: nil,
            instance_id: nil,
            target_id: nil,
            session_id: nil

  @type t :: %__MODULE__{
          version: pos_integer(),
          id: String.t(),
          instance_id: integer() | atom() | String.t(),
          target_id: String.t() | nil,
          session_id: String.t() | nil
        }

  @doc "Projects a process-local tab handle into a portable logical reference."
  @spec new(Tab.t()) :: {:ok, t()} | {:error, term()}
  def new(%Tab{} = tab) do
    with :ok <- validate_instance_id(tab.instance_id),
         {:ok, id} <- tab_id(tab) do
      {:ok,
       %__MODULE__{
         id: id,
         instance_id: tab.instance_id,
         target_id: tab.target_id,
         session_id: tab.session_id
       }}
    end
  end

  @doc """
  Projects a reference into the JSON-safe map used at the Action boundary.

  Spectre validates Action arguments against a JSON-Schema subset in which a
  struct is not an object, so the Lens Action provider carries this map rather
  than the struct itself. An atom instance id has no JSON form and would not
  survive the round trip `resolve_tab/2` depends on, so it is rejected here
  instead of being silently stringified.
  """
  @spec to_map(t()) :: {:ok, map()} | {:error, term()}
  def to_map(%__MODULE__{} = ref) do
    with :ok <- portable_instance_id(ref.instance_id) do
      {:ok,
       %{
         "version" => ref.version,
         "id" => ref.id,
         "instance_id" => ref.instance_id,
         "target_id" => ref.target_id,
         "session_id" => ref.session_id
       }}
    end
  end

  @doc "Rebuilds a reference from its `to_map/1` projection."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) and not is_struct(map) do
    with {:ok, id} <- fetch_string(map, "id"),
         {:ok, instance_id} <- fetch_instance_id(map),
         {:ok, target_id} <- fetch_optional_string(map, "target_id"),
         {:ok, session_id} <- fetch_optional_string(map, "session_id"),
         {:ok, version} <- fetch_version(map) do
      {:ok,
       %__MODULE__{
         version: version,
         id: id,
         instance_id: instance_id,
         target_id: target_id,
         session_id: session_id
       }}
    end
  end

  def from_map(invalid), do: {:error, {:invalid_lens_tab_ref, invalid}}

  @doc false
  @spec matches?(t(), Tab.t()) :: boolean()
  def matches?(%__MODULE__{} = ref, %Tab{} = tab) do
    case new(tab) do
      {:ok, candidate} -> candidate == ref
      {:error, _reason} -> false
    end
  end

  @spec portable_instance_id(term()) :: :ok | {:error, term()}
  defp portable_instance_id(value) when is_integer(value) or is_binary(value), do: :ok

  defp portable_instance_id(value),
    do: {:error, {:nonportable_lens_tab_instance_id, value}}

  @spec fetch_instance_id(map()) :: {:ok, integer() | String.t()} | {:error, term()}
  defp fetch_instance_id(map) do
    case Map.get(map, "instance_id", Map.get(map, :instance_id)) do
      value when is_integer(value) or (is_binary(value) and value != "") -> {:ok, value}
      value -> {:error, {:invalid_lens_tab_instance_id, value}}
    end
  end

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_string(map, key) do
    case field(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_lens_tab_ref_field, key, value}}
    end
  end

  @spec fetch_optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  defp fetch_optional_string(map, key) do
    case field(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_lens_tab_ref_field, key, value}}
    end
  end

  @spec fetch_version(map()) :: {:ok, pos_integer()} | {:error, term()}
  defp fetch_version(map) do
    case field(map, "version") do
      nil -> {:ok, @version}
      @version -> {:ok, @version}
      value -> {:error, {:unsupported_lens_tab_ref_version, value}}
    end
  end

  @spec field(map(), String.t()) :: term()
  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  @spec validate_instance_id(term()) :: :ok | {:error, term()}
  defp validate_instance_id(value)
       when is_integer(value) or is_binary(value) or (is_atom(value) and not is_nil(value)),
       do: :ok

  defp validate_instance_id(value), do: {:error, {:invalid_lens_tab_instance_id, value}}

  @spec tab_id(Tab.t()) :: {:ok, binary()} | {:error, term()}
  defp tab_id(%Tab{id: id}) when is_binary(id) and id != "", do: {:ok, id}

  defp tab_id(%Tab{instance_id: instance_id, target_id: target_id, session_id: session_id})
       when (is_binary(target_id) and target_id != "") or
              (is_binary(session_id) and session_id != "") do
    id =
      {instance_id, target_id, session_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    {:ok, id}
  end

  defp tab_id(%Tab{target_id: target_id, session_id: session_id}),
    do: {:error, {:invalid_lens_tab_identity, target_id, session_id}}
end
