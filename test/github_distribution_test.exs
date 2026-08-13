defmodule SpectreLens.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "Spectre comes from Hex while Lens remains GitHub-only" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    assert {:spectre, "~> 0.3.0", opts} = dependency
    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :github)
    refute Keyword.has_key?(opts, :path)
    refute Keyword.has_key?(config, :package)
  end
end
