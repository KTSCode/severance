defmodule Severance.Updater do
  @moduledoc """
  Self-update mechanism that checks GitHub releases for newer versions
  and replaces the current binary.

  Queries the GitHub Releases API, compares the latest tag against the
  compiled version, and downloads the platform-appropriate binary when
  an update is available.

  ## Options

  The `run/1` function accepts keyword options for testability:

  - `:http_get` — `(String.t() -> {:ok, binary()} | {:error, term()})`,
    defaults to HTTPS via `:httpc`
  - `:binary_path` — path to the binary to replace, defaults to
    `System.find_executable("sev")`
  - `:arch` — system architecture string, defaults to
    `:erlang.system_info(:system_architecture)`
  """

  @version Mix.Project.config()[:version]
  @repo "KTSCode/severance"

  @doc """
  Returns the application version compiled into this binary.

  ## Examples

      iex> is_binary(Severance.Updater.current_version())
      true
  """
  @spec current_version() :: String.t()
  def current_version, do: @version

  @doc """
  Extracts a semver string from a GitHub release map.

  Strips a leading `v` prefix from the `tag_name` field if present.

  ## Examples

      iex> Severance.Updater.extract_version(%{"tag_name" => "v1.2.3"})
      {:ok, "1.2.3"}

      iex> Severance.Updater.extract_version(%{})
      {:error, :no_tag}
  """
  @spec extract_version(map()) :: {:ok, String.t()} | {:error, :no_tag}
  def extract_version(%{"tag_name" => "v" <> version}), do: {:ok, version}
  def extract_version(%{"tag_name" => version}), do: {:ok, version}
  def extract_version(_), do: {:error, :no_tag}

  @doc """
  Compares the current version against the latest available version.

  Returns `:update_available` when `latest` is strictly newer than
  `current`, or `:up_to_date` otherwise.

  ## Examples

      iex> Severance.Updater.check_version("0.1.0", "0.2.0")
      :update_available

      iex> Severance.Updater.check_version("0.2.0", "0.2.0")
      :up_to_date
  """
  @spec check_version(String.t(), String.t()) :: :update_available | :up_to_date
  def check_version(current, latest) do
    case Version.compare(current, latest) do
      :lt -> :update_available
      _ -> :up_to_date
    end
  end

  @doc """
  Returns the expected binary asset name for the given system architecture.

  ## Examples

      iex> Severance.Updater.target_name("aarch64-apple-darwin24.3.0")
      "sev_macos_arm64"

      iex> Severance.Updater.target_name("x86_64-apple-darwin24.3.0")
      "sev_macos_x86"
  """
  @spec target_name(String.t()) :: String.t()
  def target_name(arch \\ default_arch()) do
    cond do
      String.starts_with?(arch, "aarch64") -> "sev_macos_arm64"
      String.starts_with?(arch, "x86_64") -> "sev_macos_x86"
    end
  end

  @doc """
  Finds the download URL for the named asset in a GitHub release map.

  ## Examples

      iex> release = %{"assets" => [%{"name" => "sev_macos_arm64", "browser_download_url" => "https://example.com/sev"}]}
      iex> Severance.Updater.find_asset(release, "sev_macos_arm64")
      {:ok, "https://example.com/sev"}
  """
  @spec find_asset(map(), String.t()) :: {:ok, String.t()} | {:error, :asset_not_found}
  def find_asset(%{"assets" => assets}, name) do
    case Enum.find(assets, &(&1["name"] == name)) do
      %{"browser_download_url" => url} -> {:ok, url}
      nil -> {:error, :asset_not_found}
    end
  end

  @doc """
  Checks GitHub for the latest release and updates the binary if a newer
  version is available.

  Returns `:ok` on success (whether updated or already current), or
  `{:error, reason}` on failure.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    http_get = Keyword.get(opts, :http_get, &default_http_get/1)
    binary_path = Keyword.get_lazy(opts, :binary_path, &find_binary_path/0)
    arch = Keyword.get(opts, :arch, default_arch())

    with {:ok, body} <- http_get.(api_url()),
         {:ok, release} <- decode_json(body),
         {:ok, latest} <- extract_version(release),
         :update_available <- check_version(current_version(), latest),
         {:ok, asset_url} <- find_asset(release, target_name(arch)),
         {:ok, _} <- require_binary_path(binary_path),
         {:ok, data} <- http_get.(asset_url),
         :ok <- write_binary(binary_path, data) do
      IO.puts("Updated to v#{latest}")
      :ok
    else
      :up_to_date ->
        IO.puts("Already on latest version (v#{current_version()})")
        :ok

      {:error, reason} ->
        IO.puts("Update failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec api_url() :: String.t()
  defp api_url do
    "https://api.github.com/repos/#{@repo}/releases/latest"
  end

  @spec default_arch() :: String.t()
  defp default_arch do
    :erlang.system_info(:system_architecture) |> List.to_string()
  end

  @spec find_binary_path() :: String.t() | nil
  defp find_binary_path do
    System.find_executable("sev")
  end

  @spec require_binary_path(String.t() | nil) :: {:ok, String.t()} | {:error, :binary_not_found}
  defp require_binary_path(nil), do: {:error, :binary_not_found}
  defp require_binary_path(path), do: {:ok, path}

  @spec decode_json(binary()) :: {:ok, map()} | {:error, term()}
  defp decode_json(body) do
    {:ok, :json.decode(body)}
  rescue
    e -> {:error, {:json_decode, e}}
  end

  @spec write_binary(String.t(), binary()) :: :ok | {:error, term()}
  defp write_binary(path, data) do
    tmp_path = path <> ".update"

    with :ok <- File.write(tmp_path, data),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, 0o755) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  @spec default_http_get(String.t()) :: {:ok, binary()} | {:error, term()}
  defp default_http_get(url) do
    headers = [
      {~c"user-agent", ~c"severance-updater"},
      {~c"accept", ~c"application/octet-stream"}
    ]

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ],
      autoredirect: true
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
