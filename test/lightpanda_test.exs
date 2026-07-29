defmodule SpectreLens.LightpandaTest do
  use ExUnit.Case, async: true

  alias SpectreLens.Lightpanda

  @current_script """
  #!/bin/sh
  if [ "$1" = "version" ]; then
    echo "1.0.0-nightly.8362+test"
    exit 0
  fi
  exit 1
  """

  test "accepts the current nightly contract and rejects older or malformed versions" do
    assert Lightpanda.minimum_version() == "1.0.0-nightly.8362"
    assert Lightpanda.compatible_version?("1.0.0-nightly.8362")
    assert Lightpanda.compatible_version?("Lightpanda 1.0.0-nightly.8362+5fe387a4")
    assert Lightpanda.compatible_version?("1.0.0")
    refute Lightpanda.compatible_version?("1.0.0-nightly.8361")
    refute Lightpanda.compatible_version?("nightly")
  end

  test "builds current serve arguments with safe defaults" do
    assert {:ok, args} =
             Lightpanda.serve_args("127.0.0.1", 9_222,
               serve_args: ["--future-option", "value"],
               log_level: "info"
             )

    assert Enum.take(args, 3) == ["serve", "--future-option", "value"]
    assert option(args, "--host") == "127.0.0.1"
    assert option(args, "--port") == "9222"
    assert option(args, "--http-timeout") == "10000"
    assert option(args, "--watchdog-ms") == "30000"
    assert option(args, "--log-level") == "info"
    assert "--disable-metrics" in args
    assert "--obey-robots" in args
    assert "--block-private-networks" in args
    refute "--timeout" in args
  end

  test "allows private addresses only through the explicit network policy" do
    assert {:ok, args} =
             Lightpanda.serve_args("127.0.0.1", 9_222,
               network_policy: :any,
               disable_metrics: false,
               obey_robots: false
             )

    refute "--block-private-networks" in args
    refute "--disable-metrics" in args
    refute "--obey-robots" in args
  end

  test "does not let raw arguments override managed safety options" do
    assert {:error, {:managed_lightpanda_serve_arg, "--host=0.0.0.0"}} =
             Lightpanda.serve_args("127.0.0.1", 9_222, serve_args: ["--host=0.0.0.0"])

    assert {:error, {:managed_lightpanda_serve_arg, "--block-private-networks"}} =
             Lightpanda.serve_args("127.0.0.1", 9_222, serve_args: ["--block-private-networks"])

    assert {:error, {:invalid_lightpanda_serve_args, ["--"]}} =
             Lightpanda.serve_args("127.0.0.1", 9_222, serve_args: ["--"])
  end

  test "resolves the official platform asset only with a release digest" do
    checksum = String.duplicate("a", 64)

    release = %{
      "tag_name" => "nightly",
      "assets" => [
        %{
          "name" => "lightpanda-x86_64-linux",
          "browser_download_url" => "https://example.invalid/lightpanda",
          "digest" => "sha256:" <> checksum
        }
      ]
    }

    assert {:ok,
            %{
              name: "lightpanda-x86_64-linux",
              url: "https://example.invalid/lightpanda",
              sha256: ^checksum,
              release: "nightly"
            }} =
             Lightpanda.release_asset(
               release: release,
               os: {:unix, :linux},
               arch: "x86_64-linux-gnu"
             )

    missing_digest = put_in(release, ["assets", Access.at(0), "digest"], nil)

    assert {:error, {:missing_release_checksum, nil}} =
             Lightpanda.release_asset(
               release: missing_digest,
               os: {:unix, :linux},
               arch: "x86_64-linux-gnu"
             )
  end

  test "installs a verified binary through an atomic temporary file" do
    directory = temporary_directory()
    checksum = sha256(@current_script)
    downloader = fn _url, destination -> File.write(destination, @current_script) end

    assert {:ok, path} =
             Lightpanda.install(
               out: directory,
               url: "https://mirror.invalid/lightpanda",
               sha256: checksum,
               downloader: downloader
             )

    assert path == Path.join(directory, "lightpanda")
    assert File.read!(path) == @current_script
    assert Lightpanda.version(binary: path) == "1.0.0-nightly.8362+test"
    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  test "a checksum failure preserves an existing installation and removes partial files" do
    directory = temporary_directory()
    destination = Path.join(directory, "lightpanda")
    :ok = File.write(destination, "existing")
    downloader = fn _url, path -> File.write(path, @current_script) end
    wrong_checksum = String.duplicate("0", 64)

    assert {:error, {:checksum_mismatch, ^wrong_checksum, _actual}} =
             Lightpanda.install(
               out: directory,
               force: true,
               url: "https://mirror.invalid/lightpanda",
               sha256: wrong_checksum,
               downloader: downloader
             )

    assert File.read!(destination) == "existing"
    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  defp option(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _pair -> nil
    end)
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp temporary_directory do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    path = Path.join(System.tmp_dir!(), "spectre-lens-lightpanda-test-" <> suffix)
    :ok = File.mkdir_p(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
