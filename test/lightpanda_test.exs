defmodule SpectreLens.LightpandaTest do
  use ExUnit.Case, async: false

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

  test "binary discovery and ensure never replace an existing executable" do
    directory = temporary_directory()
    path = write_script(directory, "custom-lightpanda", @current_script)

    assert {:ok, expanded} = Lightpanda.detect(binary: path)
    assert expanded == Path.expand(path)
    assert {:ok, ^expanded} = Lightpanda.ensure(binary: path)
    assert Lightpanda.version(binary: path) == "1.0.0-nightly.8362+test"

    File.chmod!(path, 0o644)

    assert {:error, :not_found} =
             without_detectable_lightpanda(fn -> Lightpanda.detect(binary: path) end)

    assert {:error, :lightpanda_install_url_required} =
             without_detectable_lightpanda(fn ->
               Lightpanda.ensure(
                 binary: path,
                 out: directory,
                 force: true,
                 sha256: String.duplicate("a", 64)
               )
             end)
  end

  test "platform resolution supports current Linux and macOS architectures explicitly" do
    assert {:ok, url} =
             Lightpanda.install_url(
               channel: :nightly,
               os: :linux,
               arch: "aarch64-unknown-linux-gnu"
             )

    assert String.ends_with?(url, "/lightpanda-aarch64-linux")

    assert {:ok, mac_arm} = Lightpanda.install_url(os: :darwin, arch: "arm64")
    assert String.ends_with?(mac_arm, "/lightpanda-aarch64-macos")

    assert {:ok, mac_intel} =
             Lightpanda.install_url(os: {:unix, :darwin}, arch: "amd64")

    assert String.ends_with?(mac_intel, "/lightpanda-x86_64-macos")

    assert {:error, {:unsupported_architecture, "riscv64"}} =
             Lightpanda.install_url(os: :linux, arch: "riscv64")

    assert {:error, {:unsupported_architecture, "ppc64"}} =
             Lightpanda.install_url(os: :darwin, arch: "ppc64")

    assert {:error, {:unsupported_platform, :freebsd}} =
             Lightpanda.install_url(os: :freebsd, arch: "x86_64")
  end

  test "release metadata rejects missing, malformed and untrusted assets" do
    checksum = String.duplicate("B", 64)
    artifact = "lightpanda-x86_64-linux"

    assert {:ok, %{sha256: normalized, release: "nightly"}} =
             Lightpanda.release_asset(
               os: :linux,
               arch: "amd64",
               release: %{
                 tag_name: "nightly",
                 assets: [
                   %{
                     name: artifact,
                     browser_download_url: "https://example.invalid/lightpanda",
                     digest: checksum
                   }
                 ]
               }
             )

    assert normalized == String.downcase(checksum)

    assert {:error, {:release_asset_not_found, ^artifact}} =
             Lightpanda.release_asset(
               os: :linux,
               arch: "amd64",
               release: %{"assets" => []}
             )

    assert {:error, {:invalid_release_asset, ^artifact}} =
             Lightpanda.release_asset(
               os: :linux,
               arch: "amd64",
               release: %{"assets" => [%{"name" => artifact, "digest" => checksum}]}
             )

    assert {:error, {:invalid_release_checksum, "not-a-digest"}} =
             Lightpanda.release_asset(
               os: :linux,
               arch: "amd64",
               release: %{
                 "assets" => [
                   %{
                     "name" => artifact,
                     "browser_download_url" => "https://example.invalid/lightpanda",
                     "digest" => "not-a-digest"
                   }
                 ]
               }
             )

    assert {:error, {:invalid_release_metadata, :invalid}} =
             Lightpanda.release_asset(os: :linux, arch: "amd64", release: :invalid)
  end

  test "installation validates destination, asset and downloader failures atomically" do
    directory = temporary_directory()
    destination = Path.join(directory, "lightpanda")
    :ok = File.write(destination, "keep")
    checksum = sha256(@current_script)

    assert {:error, {:already_exists, ^destination}} =
             Lightpanda.install(
               out: directory,
               asset: %{
                 url: "https://example.invalid/lightpanda",
                 sha256: checksum
               }
             )

    assert {:error, {:invalid_release_asset_url, nil}} =
             Lightpanda.install(
               out: directory,
               force: true,
               asset: %{sha256: checksum}
             )

    assert {:error, {:missing_release_checksum, nil}} =
             Lightpanda.install(
               out: directory,
               force: true,
               url: "https://example.invalid/lightpanda"
             )

    assert {:error, {:invalid_release_checksum, "bad"}} =
             Lightpanda.install(
               out: directory,
               force: true,
               asset: %{
                 browser_download_url: "https://example.invalid/lightpanda",
                 digest: "bad"
               }
             )

    assert {:error, {:invalid_lightpanda_downloader, :invalid}} =
             Lightpanda.install(
               out: directory,
               force: true,
               url: "https://example.invalid/lightpanda",
               sha256: checksum,
               downloader: :invalid
             )

    assert {:error, {:download_failed, %RuntimeError{message: "offline"}}} =
             Lightpanda.install(
               out: directory,
               force: true,
               url: "https://example.invalid/lightpanda",
               sha256: checksum,
               downloader: fn _url, _path -> raise "offline" end
             )

    assert {:error, {:download_failed, {:throw, :offline}}} =
             Lightpanda.install(
               out: directory,
               force: true,
               url: "https://example.invalid/lightpanda",
               sha256: checksum,
               downloader: fn _url, _path -> throw(:offline) end
             )

    assert File.read!(destination) == "keep"
    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  test "runtime validation fails safely before exposing an unusable process" do
    directory = temporary_directory()

    invalid_version =
      write_script(
        directory,
        "invalid-version",
        """
        #!/bin/sh
        echo "development"
        exit 0
        """
      )

    failed_version =
      write_script(
        directory,
        "failed-version",
        """
        #!/bin/sh
        echo "version command failed"
        exit 3
        """
      )

    exits_during_start =
      write_script(
        directory,
        "exits-during-start",
        """
        #!/bin/sh
        if [ "$1" = "version" ]; then
          echo "1.0.0-nightly.8362+test"
          exit 0
        fi
        exit 7
        """
      )

    assert {:error, {:invalid_network_policy, :private}} =
             Lightpanda.start_instance(
               binary: exits_during_start,
               network_policy: :private
             )

    assert {:error, {:invalid_lightpanda_version, "development"}} =
             Lightpanda.start_instance(binary: invalid_version)

    assert {:error, {:lightpanda_version_failed, 3, "version command failed"}} =
             Lightpanda.start_instance(binary: failed_version)

    assert {:error, {:invalid_port, 0}} =
             Lightpanda.start_instance(binary: exits_during_start, port: 0)

    assert {:error, {:invalid_lightpanda_host, 123}} =
             Lightpanda.start_instance(binary: exits_during_start, host: 123)

    assert {:error, {:unsafe_lightpanda_bind, "0.0.0.0"}} =
             Lightpanda.start_instance(binary: exits_during_start, host: "0.0.0.0")

    assert {:error, {:invalid_lightpanda_serve_args, :invalid}} =
             Lightpanda.start_instance(
               binary: exits_during_start,
               serve_args: :invalid
             )

    assert {:error, {:lightpanda_start_failed, _reason}} =
             Lightpanda.start_instance(
               binary: exits_during_start,
               host: "0.0.0.0",
               allow_remote_bind: true,
               port: free_port!(),
               startup_timeout: 50
             )

    assert {:ok, port} = Lightpanda.free_port()
    assert is_integer(port) and port > 0
  end

  test "version checking can be disabled for controlled development binaries" do
    directory = temporary_directory()

    script =
      write_script(
        directory,
        "unknown-version",
        """
        #!/bin/sh
        if [ "$1" = "version" ]; then
          echo "unversioned development build"
          exit 0
        fi
        exit 9
        """
      )

    assert {:error, {:lightpanda_start_failed, _reason}} =
             Lightpanda.start_instance(
               binary: script,
               check_version: false,
               port: free_port!(),
               startup_timeout: 50
             )

    broken =
      write_script(
        directory,
        "broken-interpreter",
        """
        #!/definitely/missing/interpreter
        """
      )

    assert {:error, {:lightpanda_version_failed, 2, ""}} =
             Lightpanda.start_instance(
               binary: broken,
               check_version: true
             )
  end

  test "serve arguments preserve advanced values without allowing managed overrides" do
    assert {:ok, args} =
             Lightpanda.serve_args("::1", 9_333,
               advertise_host: "localhost",
               ca_cert: ["one.pem", "two.pem"],
               ca_path: "/certs",
               cdp_max_connections: 4,
               cdp_max_pending_connections: 8,
               cdp_max_http_message_size: 1_024,
               cdp_max_message_size: 2_048,
               block_cidrs: ["10.0.0.0/8", "192.168.0.0/16"],
               block_urls: "tracking.invalid",
               http_connect_timeout: 100,
               http_max_concurrent: 5,
               http_max_host_open: 2,
               http_max_response_size: 4_096,
               http_proxy: "http://proxy.invalid",
               proxy_bearer_token: "token",
               log_filter_scopes: "cdp",
               log_format: "json",
               user_agent: "Spectre",
               user_agent_suffix: "Lens",
               web_bot_auth_domain: "example.test",
               web_bot_auth_key_file: "/tmp/key",
               web_bot_auth_keyid: "key-1",
               ws_max_concurrent: 3,
               v8_flags_unsafe: "--jitless",
               v8_max_heap_mb: 256,
               storage_engine: "sqlite",
               storage_sqlite_path: "/tmp/lens.sqlite",
               http_cache_dir: "/tmp/cache",
               cookie: "a=b",
               cookie_jar: "/tmp/cookies",
               insecure_disable_tls_host_verification: true,
               disable_subframes: true,
               disable_workers: true,
               enable_external_stylesheets: true
             )

    assert Enum.count(args, &(&1 == "--ca-cert")) == 2
    assert option(args, "--ca-path") == "/certs"
    assert option(args, "--block-cidrs") == "10.0.0.0/8,192.168.0.0/16"
    assert option(args, "--block-urls") == "tracking.invalid"
    assert "--insecure-disable-tls-host-verification" in args
    assert "--disable-subframes" in args
    assert "--disable-workers" in args
    assert "--enable-external-stylesheets" in args

    assert {:error, {:invalid_lightpanda_serve_args, [""]}} =
             Lightpanda.serve_args("localhost", 9_333, serve_args: [""])

    assert {:error, {:managed_lightpanda_serve_arg, "--port"}} =
             Lightpanda.serve_args("localhost", 9_333, serve_args: ["--port"])
  end

  test "doctor reports a detected compatible binary without starting it" do
    directory = temporary_directory()
    path = write_script(directory, "lightpanda", @current_script)

    assert %{
             detected?: true,
             path: ^path,
             version: "1.0.0-nightly.8362+test",
             compatible?: true,
             minimum_version: "1.0.0-nightly.8362",
             install_url: install_url
           } = Lightpanda.doctor(binary: path, os: :linux, arch: "amd64")

    assert is_binary(install_url)
    refute Lightpanda.compatible_version?(nil)
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

  defp write_script(directory, name, content) do
    path = Path.join(directory, name)
    :ok = File.write(path, content)
    :ok = File.chmod(path, 0o755)
    path
  end

  defp free_port! do
    {:ok, port} = Lightpanda.free_port()
    port
  end

  defp without_detectable_lightpanda(fun) do
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    previous_lightpanda_path = System.get_env("LIGHTPANDA_PATH")
    previous_application_path = Application.get_env(:spectre_lens, :lightpanda_path)
    empty_home = temporary_directory()

    try do
      System.put_env("PATH", "")
      System.put_env("HOME", empty_home)
      System.delete_env("LIGHTPANDA_PATH")
      Application.delete_env(:spectre_lens, :lightpanda_path)
      fun.()
    after
      restore_env("PATH", previous_path)
      restore_env("HOME", previous_home)
      restore_env("LIGHTPANDA_PATH", previous_lightpanda_path)

      if is_nil(previous_application_path) do
        Application.delete_env(:spectre_lens, :lightpanda_path)
      else
        Application.put_env(:spectre_lens, :lightpanda_path, previous_application_path)
      end
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
