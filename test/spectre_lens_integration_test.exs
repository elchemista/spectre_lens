defmodule SpectreLensIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "opens a runtime, navigates, and exports markdown when Lightpanda is available" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 1, max_tabs_per_instance: 2)

    try do
      assert {:ok, tab} = SpectreLens.new_tab(lens, url: "https://example.com")
      assert {:ok, view} = SpectreLens.look(tab, include: [:markdown, :links])
      assert view.url =~ "example.com"
      assert is_binary(view.markdown)
    after
      SpectreLens.close(lens)
    end
  end
end
