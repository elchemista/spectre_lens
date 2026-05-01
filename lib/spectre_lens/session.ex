defmodule SpectreLens.Session do
  @moduledoc """
  JSON-safe browser session snapshot.

  The snapshot intentionally stores only portable browser state: cookies plus
  current-origin web storage. Runtime-owned ETS tables keep these structs in
  memory, while callers can export/import plain maps for persistence.
  """

  @version 1

  @type storage :: %{optional(binary()) => %{optional(binary()) => binary()}}

  @type t :: %__MODULE__{
          version: pos_integer(),
          cookies: [map()],
          local_storage: storage(),
          session_storage: storage(),
          metadata: map(),
          created_at: binary(),
          updated_at: binary()
        }

  defstruct version: @version,
            cookies: [],
            local_storage: %{},
            session_storage: %{},
            metadata: %{},
            created_at: nil,
            updated_at: nil

  @doc "Builds a new normalized session snapshot."
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    now = timestamp()
    attrs = Enum.into(attrs, %{})

    %__MODULE__{
      version: @version,
      cookies: normalize_cookies(Map.get(attrs, :cookies, Map.get(attrs, "cookies", []))),
      local_storage:
        normalize_storage(Map.get(attrs, :local_storage, Map.get(attrs, "local_storage", %{}))),
      session_storage:
        normalize_storage(
          Map.get(attrs, :session_storage, Map.get(attrs, "session_storage", %{}))
        ),
      metadata: normalize_metadata(Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))),
      created_at: Map.get(attrs, :created_at, Map.get(attrs, "created_at", now)),
      updated_at: Map.get(attrs, :updated_at, Map.get(attrs, "updated_at", now))
    }
  end

  @doc "Normalizes an imported map or existing session struct."
  @spec normalize(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def normalize(%__MODULE__{} = session) do
    session
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(input) when is_map(input) or is_list(input) do
    map = Enum.into(input, %{})
    version = Map.get(map, :version, Map.get(map, "version", @version))

    if version == @version do
      {:ok, new(map)}
    else
      {:error, {:unsupported_session_version, version}}
    end
  rescue
    _ -> {:error, :invalid_session}
  end

  def normalize(_other), do: {:error, :invalid_session}

  @doc "Returns a JSON-safe plain map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    %{
      "version" => session.version,
      "cookies" => session.cookies,
      "local_storage" => session.local_storage,
      "session_storage" => session.session_storage,
      "metadata" => session.metadata,
      "created_at" => session.created_at,
      "updated_at" => session.updated_at
    }
  end

  @doc "Merges a freshly captured snapshot into an existing stored snapshot."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = stored, %__MODULE__{} = captured) do
    %__MODULE__{
      version: @version,
      cookies: captured.cookies,
      local_storage: deep_merge_storage(stored.local_storage, captured.local_storage),
      session_storage: deep_merge_storage(stored.session_storage, captured.session_storage),
      metadata: Map.merge(stored.metadata, captured.metadata),
      created_at: stored.created_at || captured.created_at,
      updated_at: timestamp()
    }
  end

  @doc "Returns true when the snapshot has storage for the origin."
  @spec storage_for_origin(t(), binary()) :: {map(), map()}
  def storage_for_origin(%__MODULE__{} = session, origin) when is_binary(origin) do
    {
      Map.get(session.local_storage, origin, %{}),
      Map.get(session.session_storage, origin, %{})
    }
  end

  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = session), do: %{session | updated_at: timestamp()}

  @spec normalize_cookies(term()) :: [map()]
  defp normalize_cookies(cookies) when is_list(cookies) do
    Enum.map(cookies, &normalize_cookie/1)
  end

  defp normalize_cookies(_other), do: []

  @spec normalize_cookie(term()) :: map()
  defp normalize_cookie(cookie) when is_map(cookie) do
    Map.new(cookie, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_cookie(other), do: %{"value" => normalize_value(other)}

  @spec normalize_storage(term()) :: storage()
  defp normalize_storage(storage) when is_map(storage) do
    Map.new(storage, fn {origin, values} ->
      {to_string(origin), normalize_storage_values(values)}
    end)
  end

  defp normalize_storage(_other), do: %{}

  @spec normalize_storage_values(term()) :: %{optional(binary()) => binary()}
  defp normalize_storage_values(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_storage_values(_other), do: %{}

  @spec normalize_metadata(term()) :: map()
  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_metadata(_other), do: %{}

  @spec normalize_value(term()) :: term()
  defp normalize_value(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize_value(value) when is_atom(value), do: to_string(value)
  defp normalize_value(value), do: value

  @spec deep_merge_storage(storage(), storage()) :: storage()
  defp deep_merge_storage(left, right) do
    Map.merge(left, right, fn _origin, old_values, new_values ->
      Map.merge(old_values, new_values)
    end)
  end

  @spec timestamp() :: binary()
  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
