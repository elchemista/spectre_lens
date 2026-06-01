defmodule Mix.Tasks.Spectre.Lens.Install do
  use Mix.Task

  @moduledoc """
  Installs the Lightpanda binary used by Spectre Lens.

      mix spectre.lens.install --channel nightly --out ~/.local/bin --force
  """

  @shortdoc "Install Lightpanda for Spectre Lens"

  @switches [channel: :string, out: :string, force: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    install_opts =
      []
      |> maybe_put(:channel, opts[:channel])
      |> maybe_put(:out, opts[:out])
      |> maybe_put(:force, opts[:force])

    case SpectreLens.Lightpanda.install(install_opts) do
      {:ok, path} -> Mix.shell().info("Lightpanda installed at #{path}")
      {:error, reason} -> Mix.raise("Lightpanda install failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
