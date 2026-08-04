defmodule Mix.Tasks.Spectre.Lens.Doctor do
  use Mix.Task

  @moduledoc """
  Prints Spectre Lens runtime diagnostics.

      mix spectre.lens.doctor
  """

  @shortdoc "Inspect Spectre Lens and Lightpanda setup"

  @impl Mix.Task
  def run(_argv) do
    ensure_lens_started!()
    SpectreLens.doctor() |> Jason.encode!(pretty: true) |> Mix.shell().info()
  end

  defp ensure_lens_started! do
    case Application.ensure_all_started(:spectre_lens) do
      {:ok, _applications} ->
        :ok

      {:error, {application, reason}} ->
        Mix.raise("could not start #{application}: #{inspect(reason)}")
    end
  end
end
