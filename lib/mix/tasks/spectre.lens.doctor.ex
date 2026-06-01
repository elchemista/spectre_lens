defmodule Mix.Tasks.Spectre.Lens.Doctor do
  use Mix.Task

  @moduledoc """
  Prints Spectre Lens runtime diagnostics.

      mix spectre.lens.doctor
  """

  @shortdoc "Inspect Spectre Lens and Lightpanda setup"

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    SpectreLens.doctor() |> Jason.encode!(pretty: true) |> Mix.shell().info()
  end
end
