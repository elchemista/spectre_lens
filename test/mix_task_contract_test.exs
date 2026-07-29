defmodule SpectreLens.MixTaskContractTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.Lens.{Doctor, Install}

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "doctor prints JSON diagnostics without provisioning a browser" do
    assert :ok = Doctor.run([])
    assert_receive {:mix_shell, :info, [json]}

    assert %{
             "backend" => "Elixir.SpectreLens.Browsers.Lightpanda",
             "protocol" => "Elixir.SpectreLens.Protocol.Lightpanda",
             "protocol_valid?" => true
           } = Jason.decode!(json)
  end

  test "install task rejects unknown and half-configured mirror options before download" do
    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Install.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/must be provided together/, fn ->
      Install.run(["--url", "file:///tmp/lightpanda"])
    end

    assert_raise Mix.Error, ~r/must be provided together/, fn ->
      Install.run(["--sha256", String.duplicate("a", 64)])
    end
  end

  test "install task can atomically install a checksum-pinned local mirror" do
    directory = temporary_directory()
    source = Path.join(directory, "source-lightpanda")
    out = Path.join(directory, "bin")

    script =
      """
      #!/bin/sh
      if [ "$1" = "version" ]; then
        echo "1.0.0-nightly.8362+local"
        exit 0
      fi
      exit 1
      """

    :ok = File.write(source, script)

    checksum =
      :sha256
      |> :crypto.hash(script)
      |> Base.encode16(case: :lower)

    assert :ok =
             Install.run([
               "--channel",
               "nightly",
               "--out",
               out,
               "--force",
               "--url",
               "file://" <> source,
               "--sha256",
               checksum
             ])

    installed = Path.join(out, "lightpanda")
    assert File.read!(installed) == script
    assert_receive {:mix_shell, :info, [message]}
    assert message == "Lightpanda installed at #{installed}"
  end

  test "install task surfaces local downloader failures without leaving partial files" do
    directory = temporary_directory()

    assert_raise Mix.Error, ~r/Lightpanda install failed/, fn ->
      Install.run([
        "--out",
        directory,
        "--force",
        "--url",
        "file://" <> Path.join(directory, "missing"),
        "--sha256",
        String.duplicate("0", 64)
      ])
    end

    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  defp temporary_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-lens-mix-task-#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = File.mkdir_p(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
