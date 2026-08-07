defmodule SpectreLens.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "Spectre is a direct test-only GitHub dependency without Hex package metadata" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    assert {:spectre, opts} = dependency
    assert opts[:github] == "elchemista/spectre"
    assert opts[:tag] == "0.2.0"
    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :path)
    refute Keyword.has_key?(opts, :hex)
    refute Keyword.has_key?(config, :package)
  end
end
