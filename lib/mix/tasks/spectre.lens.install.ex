defmodule Mix.Tasks.Spectre.Lens.Install do
  use Mix.Task

  @moduledoc """
  Installs the Lightpanda binary used by Spectre Lens.

      mix spectre.lens.install --channel nightly --out ~/.local/bin --force

  Official GitHub release assets are verified with the SHA-256 digest published
  by GitHub. A trusted mirror must be supplied with both `--url` and
  `--sha256`.
  """

  @shortdoc "Install Lightpanda for Spectre Lens"

  @switches [
    channel: :string,
    out: :string,
    force: :boolean,
    url: :string,
    sha256: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")
    mirror_options_valid?(opts) || Mix.raise("--url and --sha256 must be provided together")
    ensure_lens_started!()

    install_opts =
      []
      |> maybe_put(:channel, opts[:channel])
      |> maybe_put(:out, opts[:out])
      |> maybe_put(:force, opts[:force])
      |> maybe_put(:url, opts[:url])
      |> maybe_put(:sha256, opts[:sha256])

    case SpectreLens.Lightpanda.install(install_opts) do
      {:ok, path} -> Mix.shell().info("Lightpanda installed at #{path}")
      {:error, reason} -> Mix.raise("Lightpanda install failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp mirror_options_valid?(opts) do
    is_binary(opts[:url]) == is_binary(opts[:sha256])
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
