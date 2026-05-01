defmodule SpectreLens.Lightpanda do
  @moduledoc """
  Lightpanda process, binary discovery and installation helpers.
  """

  alias SpectreLens.Telemetry

  @default_host "127.0.0.1"
  @default_timeout_seconds 30

  @type instance :: %{
          id: term(),
          host: binary(),
          port: pos_integer(),
          endpoint: binary(),
          process: term(),
          binary: binary()
        }

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
  Installs a Lightpanda nightly binary.

  Options:
    * `:out` - directory to install into, default `~/.local/bin`
    * `:force` - overwrite existing file
    * `:channel` - currently only `nightly`
  """
  @spec install(keyword()) :: {:ok, binary()} | {:error, term()}
  def install(opts \\ []) do
    Telemetry.span([:spectre_lens, :lightpanda, :install], install_metadata(opts), fn ->
      out_dir = opts[:out] || Path.dirname(default_path())
      force? = Keyword.get(opts, :force, false)
      dest = Path.join(Path.expand(out_dir), "lightpanda")

      result =
        with {:ok, url} <- install_url(opts),
             :ok <- prepare_destination(dest, force?),
             :ok <- download(url, dest),
             :ok <- File.chmod(dest, 0o755) do
          {:ok, dest}
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
  def stop_instance(%{process: {_pid, os_pid}}) do
    :exec.kill(os_pid, :sigterm)
    :ok
  catch
    _, _ -> :ok
  end

  @doc "Returns a compact diagnostic map."
  @spec doctor(keyword()) :: map()
  def doctor(opts \\ []) do
    detected = detect(opts)

    %{
      detected?: match?({:ok, _}, detected),
      path: match_value(detected),
      version: version(opts),
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
    with {:ok, binary} <- ensure(opts),
         {:ok, port} <- resolve_port(opts),
         :ok <- ensure_exec_started() do
      start_resolved_instance(binary, port, opts)
    end
  end

  @spec start_resolved_instance(binary(), pos_integer(), keyword()) ::
          {:ok, instance()} | {:error, term()}
  defp start_resolved_instance(binary, port, opts) do
    host = opts[:host] || @default_host
    timeout = opts[:timeout] || @default_timeout_seconds
    args = serve_args(host, port, timeout, opts)

    case run_lightpanda(binary, args) do
      {:ok, pid, os_pid} -> build_ready_instance({pid, os_pid}, binary, host, port, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec serve_args(binary(), pos_integer(), pos_integer(), keyword()) :: [binary()]
  defp serve_args(host, port, timeout, opts) do
    ["serve", "--host", host, "--port", to_string(port), "--timeout", to_string(timeout)] ++
      List.wrap(Keyword.get(opts, :serve_args, []))
  end

  @spec run_lightpanda(binary(), [binary()]) :: {:ok, term(), term()} | {:error, term()}
  defp run_lightpanda(binary, args) do
    command = Enum.map([binary | args], &String.to_charlist/1)

    case :exec.run(command, [:stdout, :stderr, :monitor]) do
      {:ok, pid, os_pid} -> {:ok, pid, os_pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_ready_instance(
          {term(), term()},
          binary(),
          binary(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, instance()} | {:error, term()}
  defp build_ready_instance({pid, os_pid}, binary, host, port, opts) do
    endpoint = "http://#{host}:#{port}"
    process = {pid, os_pid}

    case wait_for_ready(endpoint, opts[:startup_timeout] || 5_000) do
      :ok ->
        {:ok,
         %{
           id: opts[:id] || make_ref(),
           host: host,
           port: port,
           endpoint: endpoint,
           process: process,
           binary: binary
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

  @spec prepare_destination(binary(), boolean()) :: :ok | {:error, {:already_exists, binary()}}
  defp prepare_destination(dest, force?) do
    if File.exists?(dest) and not force? do
      {:error, {:already_exists, dest}}
    else
      File.mkdir_p!(Path.dirname(dest))
      :ok
    end
  end

  @spec download(binary(), binary()) :: :ok | {:error, term()}
  defp download(url, dest) do
    cond do
      curl = System.find_executable("curl") ->
        run_download(curl, ["-fsSL", "--retry", "3", url, "-o", dest])

      wget = System.find_executable("wget") ->
        run_download(wget, ["-q", "-O", dest, url])

      true ->
        Telemetry.emit([:spectre_lens, :lightpanda, :download_fallback], %{}, %{
          url: url,
          dest: dest,
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

  @spec run_download(binary(), [binary()]) :: :ok | {:error, term()}
  defp run_download(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:download_failed, status, output}}
    end
  end

  @spec wait_for_ready(binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp wait_for_ready(endpoint, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ready(endpoint, deadline)
  end

  @spec do_wait_for_ready(binary(), integer()) :: :ok | {:error, term()}
  defp do_wait_for_ready(endpoint, deadline) do
    case Req.get(endpoint <> "/json/version", retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          do_wait_for_ready(endpoint, deadline)
        else
          Telemetry.emit([:spectre_lens, :lightpanda, :ready_timeout], %{}, %{
            endpoint: endpoint
          })

          {:error, {:not_ready, endpoint}}
        end
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

  @spec executable?(binary()) :: boolean()
  defp executable?(path),
    do: File.regular?(path) and File.stat!(path).access in [:read, :read_write]

  @spec match_value({:ok, term()} | term()) :: term() | nil
  defp match_value({:ok, value}), do: value
  defp match_value(_), do: nil

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
