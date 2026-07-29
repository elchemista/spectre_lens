defmodule SpectreLens.Lightpanda do
  @moduledoc """
  Lightpanda process, binary discovery and installation helpers.
  """

  alias SpectreLens.Telemetry

  @default_host "127.0.0.1"
  @minimum_version "1.0.0-nightly.8362"
  @default_http_timeout 10_000
  @default_watchdog_ms 30_000
  @shutdown_timeout 5_000
  @release_api "https://api.github.com/repos/lightpanda-io/browser/releases/tags"

  @type instance :: %{
          id: term(),
          host: binary(),
          port: pos_integer(),
          endpoint: binary(),
          process: term(),
          monitor_owner: pid(),
          binary: binary(),
          version: binary()
        }

  @doc "Minimum Lightpanda release supported by this Spectre Lens version."
  @spec minimum_version() :: binary()
  def minimum_version, do: @minimum_version

  @doc "Returns the configured/default Lightpanda binary path."
  @spec default_path() :: binary()
  def default_path do
    Path.join([System.get_env("HOME") || ".", ".local", "bin", "lightpanda"])
  end

  @doc "Finds a Lightpanda binary without installing anything."
  @spec detect(keyword()) :: {:ok, binary()} | {:error, :not_found}
  def detect(opts \\ []) do
    candidates =
      [
        opts[:binary],
        Application.get_env(:spectre_lens, :lightpanda_path),
        System.get_env("LIGHTPANDA_PATH"),
        System.find_executable("lightpanda"),
        default_path()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.expand/1)

    case Enum.find(candidates, &executable?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @doc "Returns `{:ok, path}` if Lightpanda exists, otherwise installs it."
  @spec ensure(keyword()) :: {:ok, binary()} | {:error, term()}
  def ensure(opts \\ []) do
    case detect(opts) do
      {:ok, path} -> {:ok, path}
      {:error, :not_found} -> install(opts)
    end
  end

  @doc """
  Installs a checksum-verified Lightpanda release atomically.

  Options:
    * `:out` - directory to install into, default `~/.local/bin`
    * `:force` - overwrite existing file
    * `:channel` - GitHub release tag, default `nightly`
    * `:url` and `:sha256` - an explicit trusted mirror and checksum
  """
  @spec install(keyword()) :: {:ok, binary()} | {:error, term()}
  def install(opts \\ []) do
    Telemetry.span([:spectre_lens, :lightpanda, :install], install_metadata(opts), fn ->
      out_dir = opts[:out] || Path.dirname(default_path())
      force? = Keyword.get(opts, :force, false)
      dest = Path.join(Path.expand(out_dir), "lightpanda")

      result =
        with :ok <- prepare_destination(dest, force?),
             {:ok, asset} <- install_asset(opts) do
          install_asset_at(asset, dest, opts)
        end

      {result, %{result: result, dest: dest}}
    end)
  end

  @doc "Returns the platform-specific nightly download URL."
  @spec install_url(keyword()) :: {:ok, binary()} | {:error, term()}
  def install_url(opts \\ []) do
    channel = Keyword.get(opts, :channel, "nightly") |> to_string()
    os = Keyword.get(opts, :os, :os.type())
    arch = Keyword.get(opts, :arch, :erlang.system_info(:system_architecture) |> to_string())

    with {:ok, artifact} <- artifact(os, arch) do
      {:ok, "https://github.com/lightpanda-io/browser/releases/download/#{channel}/#{artifact}"}
    end
  end

  @doc "Returns the official release asset and SHA-256 digest for this platform."
  @spec release_asset(keyword()) :: {:ok, map()} | {:error, term()}
  def release_asset(opts \\ []) do
    channel = Keyword.get(opts, :channel, "nightly") |> to_string()
    os = Keyword.get(opts, :os, :os.type())
    arch = Keyword.get(opts, :arch, :erlang.system_info(:system_architecture) |> to_string())

    with {:ok, artifact} <- artifact(os, arch),
         {:ok, release} <- fetch_release(channel, opts),
         {:ok, asset} <- find_release_asset(release, artifact),
         {:ok, checksum} <- normalize_checksum(map_value(asset, "digest")) do
      {:ok,
       %{
         name: artifact,
         url: map_value(asset, "browser_download_url"),
         sha256: checksum,
         release: map_value(release, "tag_name") || channel
       }}
    end
  end

  @doc "Returns the installed Lightpanda version string, or `nil`."
  @spec version(keyword()) :: binary() | nil
  def version(opts \\ []) do
    with {:ok, binary} <- detect(opts),
         {output, 0} <- System.cmd(binary, ["version"], stderr_to_stdout: true) do
      String.trim(output)
    else
      _ -> nil
    end
  end

  @doc "Checks whether a Lightpanda version satisfies the runtime contract."
  @spec compatible_version?(binary()) :: boolean()
  def compatible_version?(version) when is_binary(version) do
    case parse_version(version) do
      {:ok, parsed} ->
        Version.compare(parsed, Version.parse!(@minimum_version)) in [:eq, :gt]

      :error ->
        false
    end
  end

  def compatible_version?(_version), do: false

  @doc "Starts one Lightpanda CDP server instance."
  @spec start_instance(keyword()) :: {:ok, instance()} | {:error, term()}
  def start_instance(opts \\ []) do
    Telemetry.span([:spectre_lens, :lightpanda, :start_instance], start_metadata(opts), fn ->
      result = do_start_instance(opts)
      {result, %{result: result}}
    end)
  end

  @doc "Stops a Lightpanda instance started by `start_instance/1`."
  @spec stop_instance(map()) :: :ok
  def stop_instance(%{process: {pid, os_pid}} = instance) do
    :exec.stop(os_pid)

    if Map.get(instance, :monitor_owner) == self() do
      await_process_down(pid, os_pid, @shutdown_timeout)
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc "Returns a compact diagnostic map."
  @spec doctor(keyword()) :: map()
  def doctor(opts \\ []) do
    detected = detect(opts)
    installed_version = version(opts)

    %{
      detected?: match?({:ok, _}, detected),
      path: match_value(detected),
      version: installed_version,
      minimum_version: @minimum_version,
      compatible?: compatible_version?(installed_version || ""),
      default_path: default_path(),
      install_url: match_value(install_url(opts)),
      telemetry_disabled?: System.get_env("LIGHTPANDA_DISABLE_TELEMETRY") == "true"
    }
  end

  @doc "Finds a free local TCP port."
  @spec free_port() :: {:ok, pos_integer()} | {:error, term()}
  def free_port do
    case :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resolve_port(keyword()) ::
          {:ok, pos_integer()} | {:error, {:invalid_port, term()} | term()}
  defp resolve_port(opts) do
    case opts[:port] do
      nil -> free_port()
      port when is_integer(port) and port > 0 -> {:ok, port}
      port -> {:error, {:invalid_port, port}}
    end
  end

  @spec do_start_instance(keyword()) :: {:ok, instance()} | {:error, term()}
  defp do_start_instance(opts) do
    with :ok <- SpectreLens.URLPolicy.validate_options(SpectreLens.URLPolicy.take_options(opts)),
         {:ok, binary} <- runtime_binary(opts),
         {:ok, version} <- validate_runtime_version(binary, opts),
         {:ok, port} <- resolve_port(opts),
         {:ok, host} <- validate_host(opts[:host] || @default_host, opts),
         :ok <- ensure_exec_started() do
      start_resolved_instance(binary, version, host, port, opts)
    end
  end

  @spec runtime_binary(keyword()) :: {:ok, binary()} | {:error, term()}
  defp runtime_binary(opts) do
    case detect(opts) do
      {:ok, binary} -> {:ok, binary}
      {:error, :not_found} -> {:error, {:lightpanda_not_found, default_path()}}
    end
  end

  @spec start_resolved_instance(binary(), binary(), binary(), pos_integer(), keyword()) ::
          {:ok, instance()} | {:error, term()}
  defp start_resolved_instance(binary, version, host, port, opts) do
    with {:ok, args} <- serve_args(host, port, opts) do
      case run_lightpanda(binary, args) do
        {:ok, pid, os_pid} ->
          build_ready_instance({pid, os_pid}, binary, version, host, port, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec serve_args(binary(), pos_integer(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  def serve_args(host, port, opts \\ []) do
    with :ok <-
           SpectreLens.URLPolicy.validate_options(SpectreLens.URLPolicy.take_options(opts)),
         {:ok, extra_args} <- validate_serve_args(Keyword.get(opts, :serve_args, [])) do
      args =
        ["serve", "--host", host, "--port", to_string(port)]
        |> put_option("--advertise-host", opts[:advertise_host])
        |> put_repeated_option("--ca-cert", opts[:ca_cert])
        |> put_repeated_option("--ca-path", opts[:ca_path])
        |> put_option("--cdp-max-connections", opts[:cdp_max_connections])
        |> put_option("--cdp-max-pending-connections", opts[:cdp_max_pending_connections])
        |> put_option("--cdp-max-http-message-size", opts[:cdp_max_http_message_size])
        |> put_option("--cdp-max-message-size", opts[:cdp_max_message_size])
        |> put_flag("--disable-metrics", Keyword.get(opts, :disable_metrics, true))
        |> put_flag("--obey-robots", Keyword.get(opts, :obey_robots, true))
        |> put_flag("--block-private-networks", public_network_policy?(opts))
        |> put_option("--block-cidrs", csv(opts[:block_cidrs]))
        |> put_option("--block-urls", csv(opts[:block_urls]))
        |> put_option("--http-connect-timeout", opts[:http_connect_timeout])
        |> put_option("--http-timeout", Keyword.get(opts, :http_timeout, @default_http_timeout))
        |> put_option("--http-max-concurrent", opts[:http_max_concurrent])
        |> put_option("--http-max-host-open", opts[:http_max_host_open])
        |> put_option("--http-max-response-size", opts[:http_max_response_size])
        |> put_option("--http-proxy", opts[:http_proxy])
        |> put_option("--proxy-bearer-token", opts[:proxy_bearer_token])
        |> put_option("--log-filter-scopes", opts[:log_filter_scopes])
        |> put_option("--log-format", opts[:log_format])
        |> put_option("--log-level", opts[:log_level])
        |> put_option("--user-agent", opts[:user_agent])
        |> put_option("--user-agent-suffix", opts[:user_agent_suffix])
        |> put_option("--watchdog-ms", Keyword.get(opts, :watchdog_ms, @default_watchdog_ms))
        |> put_option("--web-bot-auth-domain", opts[:web_bot_auth_domain])
        |> put_option("--web-bot-auth-key-file", opts[:web_bot_auth_key_file])
        |> put_option("--web-bot-auth-keyid", opts[:web_bot_auth_keyid])
        |> put_option("--ws-max-concurrent", opts[:ws_max_concurrent])
        |> put_option("--v8-flags-unsafe", opts[:v8_flags_unsafe])
        |> put_option("--v8-max-heap-mb", opts[:v8_max_heap_mb])
        |> put_option("--storage-engine", opts[:storage_engine])
        |> put_option("--storage-sqlite-path", opts[:storage_sqlite_path])
        |> put_option("--http-cache-dir", opts[:http_cache_dir])
        |> put_option("--cookie", opts[:cookie])
        |> put_option("--cookie-jar", opts[:cookie_jar])
        |> put_flag(
          "--insecure-disable-tls-host-verification",
          Keyword.get(opts, :insecure_disable_tls_host_verification, false)
        )
        |> put_flag("--disable-subframes", Keyword.get(opts, :disable_subframes, false))
        |> put_flag("--disable-workers", Keyword.get(opts, :disable_workers, false))
        |> put_flag(
          "--enable-external-stylesheets",
          Keyword.get(opts, :enable_external_stylesheets, false)
        )

      ["serve" | managed_args] = args
      {:ok, ["serve" | extra_args ++ managed_args]}
    end
  end

  @spec run_lightpanda(binary(), [binary()]) :: {:ok, term(), term()} | {:error, term()}
  defp run_lightpanda(binary, args) do
    command = Enum.map([binary | args], &String.to_charlist/1)

    case :exec.run(command, [:stdout, :stderr, :monitor, {:kill_timeout, 5}]) do
      {:ok, pid, os_pid} -> {:ok, pid, os_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_ready_instance(
          {term(), term()},
          binary(),
          binary(),
          binary(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, instance()} | {:error, term()}
  defp build_ready_instance({pid, os_pid}, binary, version, host, port, opts) do
    endpoint = "http://#{endpoint_host(host)}:#{port}"
    process = {pid, os_pid}

    case wait_for_ready(endpoint, process, opts[:startup_timeout] || 10_000) do
      :ok ->
        {:ok,
         %{
           id: opts[:id] || make_ref(),
           host: host,
           port: port,
           endpoint: endpoint,
           process: process,
           monitor_owner: self(),
           binary: binary,
           version: version
         }}

      {:error, reason} ->
        stop_instance(%{process: process})
        {:error, reason}
    end
  end

  @spec artifact(term(), binary()) :: {:ok, binary()} | {:error, term()}
  defp artifact({:unix, :linux}, arch), do: linux_artifact(arch)
  defp artifact({:unix, :darwin}, arch), do: macos_artifact(arch)
  defp artifact(:linux, arch), do: linux_artifact(arch)
  defp artifact(:darwin, arch), do: macos_artifact(arch)
  defp artifact(other, _arch), do: {:error, {:unsupported_platform, other}}

  @spec linux_artifact(binary()) :: {:ok, binary()} | {:error, term()}
  defp linux_artifact(arch) do
    cond do
      String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") ->
        {:ok, "lightpanda-x86_64-linux"}

      String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") ->
        {:ok, "lightpanda-aarch64-linux"}

      true ->
        {:error, {:unsupported_architecture, arch}}
    end
  end

  @spec macos_artifact(binary()) :: {:ok, binary()} | {:error, term()}
  defp macos_artifact(arch) do
    cond do
      String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") ->
        {:ok, "lightpanda-aarch64-macos"}

      String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") ->
        {:ok, "lightpanda-x86_64-macos"}

      true ->
        {:error, {:unsupported_architecture, arch}}
    end
  end

  @spec prepare_destination(binary(), boolean()) :: :ok | {:error, term()}
  defp prepare_destination(dest, force?) do
    if File.exists?(dest) and not force? do
      {:error, {:already_exists, dest}}
    else
      File.mkdir_p(Path.dirname(dest))
    end
  end

  @spec install_asset(keyword()) :: {:ok, map()} | {:error, term()}
  defp install_asset(opts) do
    cond do
      is_map(opts[:asset]) ->
        normalize_install_asset(opts[:asset])

      is_binary(opts[:url]) ->
        normalize_install_asset(%{
          name: Path.basename(opts[:url]),
          url: opts[:url],
          sha256: opts[:sha256],
          release: :custom
        })

      not is_nil(opts[:sha256]) ->
        {:error, :lightpanda_install_url_required}

      true ->
        release_asset(opts)
    end
  end

  @spec normalize_install_asset(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_install_asset(asset) do
    url = map_value(asset, "url") || map_value(asset, "browser_download_url")
    name = map_value(asset, "name")
    release = map_value(asset, "release")
    digest = map_value(asset, "sha256") || map_value(asset, "digest")

    with true <- (is_binary(url) and url != "") or {:error, {:invalid_release_asset_url, url}},
         {:ok, checksum} <- normalize_checksum(digest) do
      {:ok, %{name: name, url: url, sha256: checksum, release: release}}
    end
  end

  @spec install_asset_at(map(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp install_asset_at(asset, dest, opts) do
    temp = temporary_destination(dest)

    result =
      with :ok <- download(asset.url, temp, opts),
           :ok <- verify_checksum(temp, asset.sha256),
           :ok <- File.chmod(temp, 0o755),
           {:ok, _version} <- validate_runtime_version(temp, opts),
           :ok <- File.rename(temp, dest) do
        {:ok, dest}
      end

    File.rm(temp)
    result
  end

  @spec temporary_destination(binary()) :: binary()
  defp temporary_destination(dest) do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    dest <> ".spectre-lens-" <> suffix <> ".tmp"
  end

  @spec download(binary(), binary(), keyword()) :: :ok | {:error, term()}
  defp download(url, dest, opts) do
    case opts[:downloader] do
      downloader when is_function(downloader, 2) ->
        downloader.(url, dest)

      nil ->
        system_download(url, dest)

      invalid ->
        {:error, {:invalid_lightpanda_downloader, invalid}}
    end
  rescue
    error -> {:error, {:download_failed, error}}
  catch
    kind, reason -> {:error, {:download_failed, {kind, reason}}}
  end

  @spec system_download(binary(), binary()) :: :ok | {:error, term()}
  defp system_download(url, dest) do
    cond do
      curl = System.find_executable("curl") ->
        run_download(curl, ["-fsSL", "--retry", "3", url, "-o", dest])

      wget = System.find_executable("wget") ->
        run_download(wget, ["-q", "-O", dest, url])

      true ->
        Telemetry.emit([:spectre_lens, :lightpanda, :download_fallback], %{}, %{
          adapter: :req
        })

        case Req.get(url, retry: :transient) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            File.write(dest, body)

          {:ok, %{status: status}} ->
            {:error, {:download_failed, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec verify_checksum(binary(), binary()) :: :ok | {:error, term()}
  defp verify_checksum(path, expected) do
    case file_checksum(path) do
      {:ok, actual} ->
        if :crypto.hash_equals(actual, expected) do
          :ok
        else
          {:error, {:checksum_mismatch, expected, actual}}
        end

      {:error, reason} ->
        {:error, {:checksum_failed, reason}}
    end
  rescue
    error -> {:error, {:checksum_failed, error}}
  end

  @spec file_checksum(binary()) :: {:ok, binary()} | {:error, term()}
  defp file_checksum(path) do
    File.open(path, [:read, :binary], fn device ->
      device
      |> IO.binstream(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
        :crypto.hash_update(context, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end)
  end

  @spec run_download(binary(), [binary()]) :: :ok | {:error, term()}
  defp run_download(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:download_failed, status, output}}
    end
  end

  @spec fetch_release(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  defp fetch_release(channel, opts) do
    case opts[:release] do
      release when is_map(release) ->
        {:ok, release}

      nil ->
        url = @release_api <> "/" <> URI.encode_www_form(channel)

        case Req.get(url,
               retry: :transient,
               headers: [
                 {"accept", "application/vnd.github+json"},
                 {"user-agent", "spectre-lens/#{SpectreLens.version()}"},
                 {"x-github-api-version", "2022-11-28"}
               ]
             ) do
          {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
            {:ok, body}

          {:ok, %{status: status}} ->
            {:error, {:release_metadata_failed, status}}

          {:error, reason} ->
            {:error, {:release_metadata_failed, reason}}
        end

      invalid ->
        {:error, {:invalid_release_metadata, invalid}}
    end
  end

  @spec find_release_asset(map(), binary()) :: {:ok, map()} | {:error, term()}
  defp find_release_asset(release, artifact) do
    release
    |> map_value("assets")
    |> List.wrap()
    |> Enum.find(&(map_value(&1, "name") == artifact))
    |> case do
      nil ->
        {:error, {:release_asset_not_found, artifact}}

      asset ->
        if is_binary(map_value(asset, "browser_download_url")) do
          {:ok, asset}
        else
          {:error, {:invalid_release_asset, artifact}}
        end
    end
  end

  @spec normalize_checksum(term()) :: {:ok, binary()} | {:error, term()}
  defp normalize_checksum("sha256:" <> checksum), do: normalize_checksum(checksum)

  defp normalize_checksum(checksum) when is_binary(checksum) do
    normalized = String.downcase(checksum)

    if String.match?(normalized, ~r/\A[0-9a-f]{64}\z/) do
      {:ok, normalized}
    else
      {:error, {:invalid_release_checksum, checksum}}
    end
  end

  defp normalize_checksum(checksum), do: {:error, {:missing_release_checksum, checksum}}

  @spec wait_for_ready(binary(), {pid(), integer()}, non_neg_integer()) ::
          :ok | {:error, term()}
  defp wait_for_ready(endpoint, process, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(endpoint, process, deadline)
  end

  @spec do_wait_for_ready(binary(), {pid(), integer()}, integer()) :: :ok | {:error, term()}
  defp do_wait_for_ready(endpoint, {pid, os_pid} = process, deadline) do
    receive do
      {:DOWN, ^os_pid, :process, ^pid, reason} ->
        {:error, {:lightpanda_start_failed, reason}}
    after
      0 ->
        check_ready_endpoint(endpoint, process, deadline)
    end
  end

  @spec check_ready_endpoint(binary(), {pid(), integer()}, integer()) ::
          :ok | {:error, term()}
  defp check_ready_endpoint(endpoint, process, deadline) do
    case Req.get(endpoint <> "/json/version", retry: false, receive_timeout: 500) do
      {:ok, %{status: status, body: %{"webSocketDebuggerUrl" => websocket}}}
      when status in 200..299 and is_binary(websocket) ->
        :ok

      _response ->
        retry_ready_endpoint(endpoint, process, deadline)
    end
  end

  @spec retry_ready_endpoint(binary(), {pid(), integer()}, integer()) ::
          :ok | {:error, term()}
  defp retry_ready_endpoint(endpoint, process, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(100)
      do_wait_for_ready(endpoint, process, deadline)
    else
      Telemetry.emit([:spectre_lens, :lightpanda, :ready_timeout], %{}, %{
        endpoint: endpoint
      })

      {:error, {:not_ready, endpoint}}
    end
  end

  @spec ensure_exec_started() :: :ok | {:error, term()}
  defp ensure_exec_started do
    case :exec.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await_process_down(pid(), integer(), non_neg_integer()) :: :ok
  defp await_process_down(pid, os_pid, timeout) do
    receive do
      {:DOWN, ^os_pid, :process, ^pid, _reason} -> :ok
    after
      timeout -> :ok
    end
  end

  @spec executable?(binary()) :: boolean()
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  @spec validate_runtime_version(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp validate_runtime_version(binary, opts) do
    case binary_version(binary) do
      {:ok, version} ->
        if Keyword.get(opts, :check_version, true) and not compatible_version?(version) do
          {:error, {:unsupported_lightpanda_version, version, @minimum_version}}
        else
          {:ok, version}
        end

      {:error, reason} ->
        if Keyword.get(opts, :check_version, true),
          do: {:error, reason},
          else: {:ok, "unknown"}
    end
  end

  @spec binary_version(binary()) :: {:ok, binary()} | {:error, term()}
  defp binary_version(binary) do
    case System.cmd(binary, ["version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = String.trim(output)

        if compatible_version_string?(version),
          do: {:ok, version},
          else: {:error, {:invalid_lightpanda_version, version}}

      {output, status} ->
        {:error, {:lightpanda_version_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:lightpanda_version_failed, error}}
  end

  @spec compatible_version_string?(binary()) :: boolean()
  defp compatible_version_string?(version), do: match?({:ok, _parsed}, parse_version(version))

  @spec parse_version(binary()) :: {:ok, Version.t()} | :error
  defp parse_version(version) do
    version
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find_value(:error, fn candidate ->
      candidate = String.trim_leading(candidate, "v")

      case Version.parse(candidate) do
        {:ok, parsed} -> {:ok, parsed}
        :error -> false
      end
    end)
  end

  @spec validate_host(term(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp validate_host(host, opts) when is_binary(host) and host != "" do
    if loopback_host?(host) or Keyword.get(opts, :allow_remote_bind, false) do
      {:ok, host}
    else
      {:error, {:unsafe_lightpanda_bind, host}}
    end
  end

  defp validate_host(host, _opts), do: {:error, {:invalid_lightpanda_host, host}}

  @spec loopback_host?(binary()) :: boolean()
  defp loopback_host?(host), do: host in ["127.0.0.1", "::1", "localhost"]

  @spec endpoint_host(binary()) :: binary()
  defp endpoint_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "["),
      do: "[" <> host <> "]",
      else: host
  end

  @spec validate_serve_args(term()) :: {:ok, [binary()]} | {:error, term()}
  defp validate_serve_args(args) when is_list(args) do
    cond do
      not Enum.all?(args, &(is_binary(&1) and &1 != "")) ->
        {:error, {:invalid_lightpanda_serve_args, args}}

      "--" in args ->
        {:error, {:invalid_lightpanda_serve_args, args}}

      Enum.any?(args, &managed_serve_arg?/1) ->
        {:error, {:managed_lightpanda_serve_arg, Enum.find(args, &managed_serve_arg?/1)}}

      true ->
        {:ok, args}
    end
  end

  defp validate_serve_args(args), do: {:error, {:invalid_lightpanda_serve_args, args}}

  @spec put_option([binary()], binary(), term()) :: [binary()]
  defp put_option(args, _flag, nil), do: args
  defp put_option(args, flag, value), do: args ++ [flag, to_string(value)]

  @spec put_flag([binary()], binary(), term()) :: [binary()]
  defp put_flag(args, flag, true), do: args ++ [flag]
  defp put_flag(args, _flag, _value), do: args

  @spec put_repeated_option([binary()], binary(), term()) :: [binary()]
  defp put_repeated_option(args, _flag, nil), do: args

  defp put_repeated_option(args, flag, values) when is_list(values) do
    Enum.reduce(values, args, &put_option(&2, flag, &1))
  end

  defp put_repeated_option(args, flag, value), do: put_option(args, flag, value)

  @spec csv(term()) :: binary() | nil
  defp csv(nil), do: nil
  defp csv(value) when is_list(value), do: Enum.map_join(value, ",", &to_string/1)
  defp csv(value), do: to_string(value)

  @spec managed_serve_flags() :: [binary()]
  defp managed_serve_flags do
    [
      "--host",
      "--port",
      "--advertise-host",
      "--ca-cert",
      "--ca-path",
      "--cdp-max-connections",
      "--cdp-max-pending-connections",
      "--cdp-max-http-message-size",
      "--cdp-max-message-size",
      "--disable-metrics",
      "--obey-robots",
      "--block-private-networks",
      "--block-cidrs",
      "--block-urls",
      "--cookie",
      "--cookie-jar",
      "--disable-subframes",
      "--disable-workers",
      "--enable-external-stylesheets",
      "--http-cache-dir",
      "--http-connect-timeout",
      "--http-max-concurrent",
      "--http-max-host-open",
      "--http-max-response-size",
      "--http-proxy",
      "--http-timeout",
      "--proxy-bearer-token",
      "--insecure-disable-tls-host-verification",
      "--log-filter-scopes",
      "--log-format",
      "--log-level",
      "--storage-engine",
      "--storage-sqlite-path",
      "--user-agent",
      "--user-agent-suffix",
      "--v8-flags-unsafe",
      "--v8-max-heap-mb",
      "--watchdog-ms",
      "--web-bot-auth-domain",
      "--web-bot-auth-key-file",
      "--web-bot-auth-keyid",
      "--ws-max-concurrent"
    ]
  end

  @spec managed_serve_arg?(binary()) :: boolean()
  defp managed_serve_arg?(arg) do
    Enum.any?(managed_serve_flags(), fn flag ->
      arg == flag or String.starts_with?(arg, flag <> "=")
    end)
  end

  @spec public_network_policy?(keyword()) :: boolean()
  defp public_network_policy?(opts),
    do: Keyword.get(opts, :network_policy, :public) == :public

  @spec match_value({:ok, term()} | term()) :: term() | nil
  defp match_value({:ok, value}), do: value
  defp match_value(_), do: nil

  @spec map_value(map(), binary()) :: term()
  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  @spec install_metadata(keyword()) :: map()
  defp install_metadata(opts) do
    %{
      channel: Keyword.get(opts, :channel, "nightly"),
      out: opts[:out] || Path.dirname(default_path()),
      force?: Keyword.get(opts, :force, false)
    }
  end

  @spec start_metadata(keyword()) :: map()
  defp start_metadata(opts) do
    %{
      id: opts[:id],
      host: opts[:host] || @default_host,
      port: opts[:port]
    }
  end
end
