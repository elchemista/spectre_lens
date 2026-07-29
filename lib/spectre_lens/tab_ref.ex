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

  @doc false
  @spec matches?(t(), Tab.t()) :: boolean()
  def matches?(%__MODULE__{} = ref, %Tab{} = tab) do
    case new(tab) do
      {:ok, candidate} -> candidate == ref
      {:error, _reason} -> false
    end
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
