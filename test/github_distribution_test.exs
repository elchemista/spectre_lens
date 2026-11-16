defmodule SpectreLens.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "Spectre uses Hex normally and the explicit compatibility path when requested" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    opts =
      case System.get_env("SPECTRE_PATH") do
        path when is_binary(path) and path != "" ->
          assert {:spectre, opts} = dependency
          assert opts[:path] == Path.expand(path, File.cwd!())
          assert opts[:override]
          opts

        _unset ->
          assert {:spectre, requirement, opts} = dependency
          assert Version.match?("0.3.3", requirement)
          refute Keyword.has_key?(opts, :path)
          opts
      end

    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :github)
    assert config[:package][:licenses] == ["Apache-2.0"]
    assert "docs" in config[:package][:files]
    refute "test" in config[:package][:files]
  end
end
