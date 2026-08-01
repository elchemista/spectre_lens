defmodule SpectreLens.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/elchemista/spectre_lens"

  def project do
    [
      app: :spectre_lens,
      name: "Spectre Lens",
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      dialyzer: dialyzer(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl]
    ]
  end

  defp deps do
    [
      spectre_dep(),
      {:jason, "~> 1.4.5"},
      {:req, "~> 0.7.1"},
      {:websockex, "~> 0.5.1"},
      {:erlexec, "~> 2.3.4"},
      {:telemetry, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp spectre_dep do
    case {System.get_env("SPECTRE_HEX_BUILD"), System.get_env("SPECTRE_PATH")} do
      {hex_build, _path} when hex_build in ["1", "true"] ->
        {:spectre, "~> 0.2.0"}

      {_hex_build, path} when is_binary(path) and path != "" ->
        {:spectre, "~> 0.2.0", path: Path.expand(path)}

      _other ->
        {:spectre, "~> 0.2.0", github: "elchemista/spectre", branch: "main"}
    end
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end

  defp description do
    "Agent-first, backend-neutral browser perception for Elixir."
  end

  defp package do
    [
      name: "spectre_lens",
      maintainers: ["Elchemista"],
      files: ~w(
        lib
        docs
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      ),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/PUBLIC_API.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end
end
