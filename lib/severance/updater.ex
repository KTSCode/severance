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
    `Init.detect_binary_path/0`
  - `:arch` — system architecture string, defaults to
    `:erlang.system_info(:system_architecture)`
  """

  alias Burrito.Util.Args, as: BurritoArgs

  @version Mix.Project.config()[:version]
  @repo "KTSCode/severance"
  @cache_table :severance_version_cache
  @cache_ttl_seconds 24 * 60 * 60

  @doc """
  Returns the application version compiled into this binary.

  ## Examples

      iex> is_binary(Severance.Updater.current_version())
      true
  """
  @spec current_version() :: String.t()
  def current_version, do: @version

  @doc """
  Creates the ETS table for caching the latest version.

  Called once at daemon startup. Safe to call multiple times — returns
  `:already_exists` if the table exists.
  """
  @spec create_cache_table() :: :ok | :already_exists
  def create_cache_table do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
      :ok
    else
      :already_exists
    end
  end

  @doc """
  Returns the latest available version, using a 24-hour ETS cache.

  Checks the cache first. If the cache is missing or older than 24 hours,
  fetches from the GitHub Releases API. On fetch failure with a stale
  cache, returns the stale value. On fetch failure with no cache, returns
  the error.

  Accepts `http_get:` option for testability.
  """
  @spec fetch_latest_version(keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_latest_version(opts \\ []) do
    now = System.system_time(:second)

    case read_cache(now) do
      {:ok, version} ->
        {:ok, version}

      :miss ->
        http_get = Keyword.get(opts, :http_get, &default_http_get/1)
        fetch_and_cache(http_get, now)

      {:stale, version} ->
        http_get = Keyword.get(opts, :http_get, &default_http_get/1)

        case fetch_and_cache(http_get, now) do
          {:ok, new_version} -> {:ok, new_version}
          {:error, _reason} -> {:ok, version}
        end
    end
  end

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
      {:ok, "sev_macos_arm64"}

      iex> Severance.Updater.target_name("x86_64-apple-darwin24.3.0")
      {:ok, "sev_macos_x86"}

      iex> Severance.Updater.target_name("riscv64-unknown-linux-gnu")
      {:error, {:unsupported_arch, "riscv64-unknown-linux-gnu"}}
  """
  @spec target_name(String.t()) :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}
  def target_name(arch \\ default_arch()) do
    cond do
      String.starts_with?(arch, "aarch64") -> {:ok, "sev_macos_arm64"}
      String.starts_with?(arch, "x86_64") -> {:ok, "sev_macos_x86"}
      true -> {:error, {:unsupported_arch, arch}}
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
  version is available. When a daemon is running, prompts the user to
  restart it so the new binary takes effect.

  Returns `:ok` on success (whether updated or already current), or
  `{:error, reason}` on failure.

  ## Options

  In addition to `:http_get`, `:binary_path`, and `:arch`, accepts
  injectable callbacks for testability:

  - `:daemon_running?` — `(() -> boolean())`, defaults to `&CLI.daemon_running?/0`
  - `:prompt_restart` — `(() -> boolean())`, defaults to reading from stdio
  - `:stop_daemon` — `(() -> :ok | {:error, term()})`, defaults to `&CLI.run_stop/0`
  - `:restart_daemon` — `((String.t()) -> :ok)`, defaults to launchctl/sh logic
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    http_get = Keyword.get(opts, :http_get, &default_http_get/1)
    binary_path = Keyword.get_lazy(opts, :binary_path, &find_binary_path/0)
    arch = Keyword.get(opts, :arch, default_arch())
    plist_path = Keyword.get(opts, :plist_path)

    with {:ok, body} <- http_get.(api_url()),
         {:ok, release} <- decode_json(body),
         {:ok, latest} <- extract_version(release),
         :update_available <- check_version(current_version(), latest),
         {:ok, target} <- target_name(arch),
         {:ok, asset_url} <- find_asset(release, target),
         {:ok, bin_path} <- require_binary_path(binary_path),
         {:ok, data} <- http_get.(asset_url),
         :ok <- write_binary(bin_path, data) do
      rewrite_plist(bin_path, plist_path)
      maybe_restart_daemon(latest, bin_path, opts)
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

  @spec read_cache(integer()) :: {:ok, String.t()} | {:stale, String.t()} | :miss
  defp read_cache(now) do
    if :ets.whereis(@cache_table) == :undefined do
      :miss
    else
      case :ets.lookup(@cache_table, :latest_version) do
        [{:latest_version, version, ts}] when now - ts < @cache_ttl_seconds ->
          {:ok, version}

        [{:latest_version, version, _ts}] ->
          {:stale, version}

        [] ->
          :miss
      end
    end
  end

  @spec fetch_and_cache((String.t() -> {:ok, binary()} | {:error, term()}), integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp fetch_and_cache(http_get, now) do
    with {:ok, body} <- http_get.(api_url()),
         {:ok, release} <- decode_json(body),
         {:ok, version} <- extract_version(release) do
      if :ets.whereis(@cache_table) != :undefined do
        :ets.insert(@cache_table, {:latest_version, version, now})
      end

      {:ok, version}
    end
  end

  @spec maybe_restart_daemon(String.t(), String.t(), keyword()) :: :ok
  defp maybe_restart_daemon(version, binary_path, opts) do
    daemon_running? = Keyword.get(opts, :daemon_running?, &Severance.CLI.daemon_running?/0)
    prompt_restart = Keyword.get(opts, :prompt_restart, &default_prompt_restart/0)
    stop_daemon = Keyword.get(opts, :stop_daemon, &Severance.CLI.run_stop/0)
    restart_daemon = Keyword.get(opts, :restart_daemon, &default_restart_daemon/1)

    if daemon_running?.() do
      IO.puts("""
      A severance daemon is currently running. Restarting will lose the
      current countdown state (phase, overtime mode, etc.).\
      """)

      if prompt_restart.() do
        stop_daemon.()
        restart_daemon.(binary_path)
        IO.puts("Updated to v#{version} and restarted")
      else
        IO.puts("Updated to v#{version}. Restart the daemon to use the new version.")
      end
    else
      IO.puts("Updated to v#{version}")
    end
  end

  @spec default_prompt_restart() :: boolean()
  defp default_prompt_restart do
    IO.write("Restart now? [y/N] ")

    case IO.read(:stdio, :line) do
      line when is_binary(line) -> String.trim(line) in ["y", "Y"]
      _ -> false
    end
  end

  @spec default_restart_daemon(String.t()) :: :ok
  defp default_restart_daemon(binary_path) do
    plist = plist_path()

    if File.exists?(plist) and agent_loaded?() do
      {uid, 0} = System.cmd("id", ["-u"])
      target = "gui/#{String.trim(uid)}"
      System.cmd("launchctl", ["bootout", target, plist], stderr_to_stdout: true)
      System.cmd("launchctl", ["bootstrap", target, plist])
    else
      System.cmd("sh", ["-c", "#{binary_path} --daemon &"])
    end

    :ok
  end

  @spec agent_loaded?() :: boolean()
  defp agent_loaded? do
    {uid, 0} = System.cmd("id", ["-u"])
    target = "gui/#{String.trim(uid)}/com.severance.daemon"

    case System.cmd("launchctl", ["print", target], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @spec rewrite_plist(String.t(), String.t() | nil) :: :ok | {:error, term()}
  defp rewrite_plist(binary_path, override_path) do
    path = override_path || plist_path()

    if override_path || File.exists?(path) do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, Severance.Init.plist_contents(binary_path)) do
        IO.puts("[plist] Updated #{path}")
        :ok
      else
        {:error, reason} ->
          IO.puts("[plist] Failed to update #{path}: #{inspect(reason)}")
          {:error, {:plist_write, reason}}
      end
    else
      :ok
    end
  end

  @spec plist_path() :: String.t()
  defp plist_path do
    Path.expand("~/Library/LaunchAgents/com.severance.daemon.plist")
  end

  @spec api_url() :: String.t()
  defp api_url do
    "https://api.github.com/repos/#{@repo}/releases/latest"
  end

  @spec default_arch() :: String.t()
  defp default_arch do
    :system_architecture |> :erlang.system_info() |> List.to_string()
  end

  @spec find_binary_path() :: String.t() | nil
  defp find_binary_path do
    case BurritoArgs.get_bin_path() do
      path when is_binary(path) -> path
      :not_in_burrito -> System.find_executable("sev")
    end
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
      {~c"accept", ~c"application/vnd.github+json"}
    ]

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
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
