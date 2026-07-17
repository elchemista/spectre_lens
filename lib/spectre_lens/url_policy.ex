defmodule SpectreLens.URLPolicy do
  @moduledoc """
  Validates URLs before Spectre Lens lets a browser or HTTP client use them.

  The default `:public` policy accepts only HTTP(S) destinations whose resolved
  addresses are public. Callers that intentionally browse a local development
  server must opt in with `network_policy: :any`.

  This policy deliberately does not claim to prevent DNS rebinding. Production
  deployments should still isolate the browser's network egress.
  """

  import Bitwise

  @option_keys [:network_policy, :allowed_ports, :resolver]
  @default_ports [80, 443]
  @blocked_names MapSet.new([
                   "instance-data",
                   "instance-data.ec2.internal",
                   "localhost",
                   "localhost.localdomain",
                   "metadata",
                   "metadata.google.internal"
                 ])

  @type policy :: :public | :any
  @type resolver :: (charlist(), :inet | :inet6 -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @doc "Returns the URL-policy options contained in a larger keyword list."
  @spec take_options(keyword()) :: keyword()
  def take_options(opts) when is_list(opts), do: Keyword.take(opts, @option_keys)

  @doc "Merges persisted tab policy with per-call policy options."
  @spec merge_options(keyword(), keyword()) :: keyword()
  def merge_options(base, opts) when is_list(base) and is_list(opts) do
    Keyword.merge(base, take_options(opts))
  end

  @doc "Validates a top-level browser or HTTP destination."
  @spec validate(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, policy} <- policy(opts),
         {:ok, uri} <- parse_http_url(url),
         :ok <- validate_port(uri, policy, opts),
         :ok <- validate_host(uri.host, policy, opts) do
      {:ok, URI.to_string(uri)}
    end
  end

  def validate(url, _opts), do: {:error, {:invalid_url, url}}

  @doc "Validates a browser subrequest, allowing non-network browser-local URLs."
  @spec validate_request(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def validate_request(url, opts \\ []) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["about", "blob", "data"] -> {:ok, url}
      _ -> validate(url, opts)
    end
  end

  @doc "Returns true when two absolute HTTP(S) URLs have the same origin."
  @spec same_origin?(binary(), binary()) :: boolean()
  def same_origin?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- origin(left),
         {:ok, right} <- origin(right) do
      left == right
    else
      _ -> false
    end
  end

  @doc "Removes credentials, query parameters and fragments from a URL for telemetry."
  @spec sanitize(binary()) :: binary()
  def sanitize(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        %{uri | userinfo: nil, query: nil, fragment: nil}
        |> URI.to_string()

      %URI{scheme: nil, host: nil, path: path} = uri when is_binary(path) ->
        %{uri | query: nil, fragment: nil}
        |> URI.to_string()

      _ ->
        "[invalid-url]"
    end
  rescue
    _ -> "[invalid-url]"
  end

  def sanitize(_url), do: "[invalid-url]"

  @doc false
  @spec public_address?(:inet.ip_address()) :: boolean()
  def public_address?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not private_ipv4?(address)
  end

  def public_address?({a, b, c, d, e, f, g, h} = address)
      when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
             e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF do
    not private_ipv6?(address)
  end

  def public_address?(_address), do: false

  @spec policy(keyword()) :: {:ok, policy()} | {:error, term()}
  defp policy(opts) do
    case Keyword.get(opts, :network_policy, :public) do
      policy when policy in [:public, :any] -> {:ok, policy}
      other -> {:error, {:invalid_network_policy, other}}
    end
  end

  @spec parse_http_url(binary()) :: {:ok, URI.t()} | {:error, term()}
  defp parse_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{uri | host: normalize_host(host)}}

      %URI{userinfo: userinfo} when not is_nil(userinfo) ->
        {:error, {:url_credentials_not_allowed, url}}

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, {:unsupported_url_scheme, scheme}}

      _ ->
        {:error, {:invalid_url, url}}
    end
  rescue
    _ -> {:error, {:invalid_url, url}}
  end

  @spec validate_port(URI.t(), policy(), keyword()) :: :ok | {:error, term()}
  defp validate_port(%URI{port: port}, :any, opts) do
    validate_allowed_port(port, Keyword.get(opts, :allowed_ports, :any))
  end

  defp validate_port(%URI{port: port}, :public, opts) do
    validate_allowed_port(port, Keyword.get(opts, :allowed_ports, @default_ports))
  end

  @spec validate_allowed_port(nil | integer(), :any | [integer()]) :: :ok | {:error, term()}
  defp validate_allowed_port(nil, _allowed), do: :ok
  defp validate_allowed_port(port, :any) when is_integer(port) and port in 1..65_535, do: :ok

  defp validate_allowed_port(port, allowed) when is_integer(port) and is_list(allowed) do
    if port in allowed, do: :ok, else: {:error, {:port_not_allowed, port}}
  end

  defp validate_allowed_port(port, _allowed), do: {:error, {:port_not_allowed, port}}

  @spec validate_host(binary(), policy(), keyword()) :: :ok | {:error, term()}
  defp validate_host(_host, :any, _opts), do: :ok

  defp validate_host(host, :public, opts) do
    cond do
      blocked_name?(host) ->
        {:error, {:host_not_allowed, host}}

      true ->
        validate_resolved_addresses(host, opts)
    end
  end

  @spec validate_resolved_addresses(binary(), keyword()) :: :ok | {:error, term()}
  defp validate_resolved_addresses(host, opts) do
    case parse_address(host) do
      {:ok, address} -> validate_public_addresses(host, [address])
      :error -> resolve_and_validate(host, opts)
    end
  end

  @spec resolve_and_validate(binary(), keyword()) :: :ok | {:error, term()}
  defp resolve_and_validate(host, opts) do
    resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)
    hostname = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case resolver.(hostname, family) do
          {:ok, resolved} when is_list(resolved) -> resolved
          _ -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [] -> {:error, {:host_resolution_failed, host}}
      addresses -> validate_public_addresses(host, addresses)
    end
  rescue
    _ -> {:error, {:host_resolution_failed, host}}
  end

  @spec validate_public_addresses(binary(), [:inet.ip_address()]) :: :ok | {:error, term()}
  defp validate_public_addresses(host, addresses) do
    case Enum.find(addresses, &(not public_address?(&1))) do
      nil -> :ok
      address -> {:error, {:address_not_allowed, host, address}}
    end
  end

  @spec blocked_name?(binary()) :: boolean()
  defp blocked_name?(host) do
    MapSet.member?(@blocked_names, host) or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local")
  end

  @spec normalize_host(binary()) :: binary()
  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  @spec parse_address(binary()) :: {:ok, :inet.ip_address()} | :error
  defp parse_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _} -> :error
    end
  end

  @spec origin(binary()) :: {:ok, {binary(), binary(), integer()}} | :error
  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        port = uri.port || if(scheme == "https", do: 443, else: 80)
        {:ok, {scheme, normalize_host(host), port}}

      _ ->
        :error
    end
  end

  @spec private_ipv4?(:inet.ip4_address()) :: boolean()
  defp private_ipv4?({a, b, c, _d}) do
    a == 0 or
      a == 10 or
      (a == 100 and b in 64..127) or
      a == 127 or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 0 and c == 0) or
      (a == 192 and b == 168) or
      (a == 192 and b == 0 and c == 2) or
      (a == 192 and b == 88 and c == 99) or
      (a == 198 and b in 18..19) or
      (a == 198 and b == 51 and c == 100) or
      (a == 203 and b == 0 and c == 113) or
      a >= 224
  end

  @spec private_ipv6?(:inet.ip6_address()) :: boolean()
  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ipv6?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    embedded_private_ipv4?(high, low)
  end

  defp private_ipv6?({0, 0, 0, 0, 0, 0, high, low}) do
    embedded_private_ipv4?(high, low)
  end

  defp private_ipv6?({0x0064, 0xFF9B, 0, 0, 0, 0, high, low}) do
    embedded_private_ipv4?(high, low)
  end

  defp private_ipv6?({0x2002, high, low, _d, _e, _f, _g, _h}) do
    embedded_private_ipv4?(high, low)
  end

  defp private_ipv6?({_a, _b, _c, _d, marker, 0x5EFE, high, low})
       when marker in [0, 0x0200] do
    embedded_private_ipv4?(high, low)
  end

  defp private_ipv6?({first, second, third, _d, _e, _f, _g, _h}) do
    (first &&& 0xFE00) == 0xFC00 or
      (first &&& 0xFFC0) == 0xFE80 or
      (first &&& 0xFF00) == 0xFF00 or
      (first == 0x0064 and second == 0xFF9B and third == 1) or
      (first == 0x2001 and second == 0) or
      (first == 0x2001 and second == 0x0DB8) or
      (first == 0x0100 and second == 0)
  end

  @spec embedded_private_ipv4?(non_neg_integer(), non_neg_integer()) :: boolean()
  defp embedded_private_ipv4?(high, low) do
    private_ipv4?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end
end
