defmodule Severance.UpdaterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Severance.Updater

  describe "current_version/0" do
    test "returns the compiled version string" do
      assert Updater.current_version() == Mix.Project.config()[:version]
    end
  end

  describe "extract_version/1" do
    test "strips v prefix from tag_name" do
      assert Updater.extract_version(%{"tag_name" => "v1.2.3"}) == {:ok, "1.2.3"}
    end

    test "handles tag_name without v prefix" do
      assert Updater.extract_version(%{"tag_name" => "1.2.3"}) == {:ok, "1.2.3"}
    end

    test "returns error when tag_name is missing" do
      assert Updater.extract_version(%{}) == {:error, :no_tag}
    end
  end

  describe "check_version/2" do
    test "returns :update_available when latest is newer" do
      assert Updater.check_version("0.1.0", "0.2.0") == :update_available
    end

    test "returns :up_to_date when versions match" do
      assert Updater.check_version("0.2.0", "0.2.0") == :up_to_date
    end

    test "returns :up_to_date when current is newer" do
      assert Updater.check_version("0.3.0", "0.2.0") == :up_to_date
    end
  end

  describe "target_name/1" do
    test "returns arm64 binary name for aarch64 architecture" do
      assert Updater.target_name("aarch64-apple-darwin24.3.0") == {:ok, "sev_macos_arm64"}
    end

    test "returns x86 binary name for x86_64 architecture" do
      assert Updater.target_name("x86_64-apple-darwin24.3.0") == {:ok, "sev_macos_x86"}
    end

    test "returns error for unsupported architecture" do
      assert Updater.target_name("riscv64-unknown-linux-gnu") ==
               {:error, {:unsupported_arch, "riscv64-unknown-linux-gnu"}}
    end
  end

  describe "find_asset/2" do
    test "returns URL for matching asset" do
      release = %{
        "assets" => [
          %{
            "name" => "sev_macos_arm64",
            "browser_download_url" => "https://example.com/arm64"
          },
          %{
            "name" => "sev_macos_x86",
            "browser_download_url" => "https://example.com/x86"
          }
        ]
      }

      assert Updater.find_asset(release, "sev_macos_arm64") ==
               {:ok, "https://example.com/arm64"}
    end

    test "returns error when no matching asset" do
      release = %{
        "assets" => [
          %{"name" => "other", "browser_download_url" => "https://example.com/other"}
        ]
      }

      assert Updater.find_asset(release, "sev_macos_arm64") == {:error, :asset_not_found}
    end

    test "returns error when assets list is empty" do
      release = %{"assets" => []}
      assert Updater.find_asset(release, "sev_macos_arm64") == {:error, :asset_not_found}
    end
  end

  describe "run/1" do
    test "reports up to date when on latest version" do
      current = Updater.current_version()

      http_get = fn _url ->
        body =
          :json.encode(%{
            "tag_name" => "v#{current}",
            "assets" => []
          })

        {:ok, IO.iodata_to_binary(body)}
      end

      output = capture_io(fn -> assert Updater.run(http_get: http_get) == :ok end)
      assert output =~ "Already on latest version"
    end

    test "updates binary when newer version available" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      binary_path = Path.join(tmp_dir, "sev")
      File.write!(binary_path, "old-binary")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      http_get = fn url ->
        if String.contains?(url, "api.github.com") do
          body =
            :json.encode(%{
              "tag_name" => "v99.0.0",
              "assets" => [
                %{
                  "name" => "sev_macos_arm64",
                  "browser_download_url" => "https://example.com/sev"
                },
                %{
                  "name" => "sev_macos_x86",
                  "browser_download_url" => "https://example.com/sev_x86"
                }
              ]
            })

          {:ok, IO.iodata_to_binary(body)}
        else
          {:ok, "new-binary-content"}
        end
      end

      output =
        capture_io(fn ->
          assert Updater.run(
                   http_get: http_get,
                   binary_path: binary_path,
                   arch: "aarch64-apple-darwin24.3.0",
                   plist_path: Path.join(tmp_dir, "test.plist")
                 ) == :ok
        end)

      assert output =~ "Updated to v99.0.0"
      assert File.read!(binary_path) == "new-binary-content"
    end

    test "returns error when API request fails" do
      http_get = fn _url -> {:error, :nxdomain} end

      capture_io(fn ->
        assert {:error, _} = Updater.run(http_get: http_get)
      end)
    end

    test "returns error when binary path is nil" do
      current = Updater.current_version()
      next_version = bump_patch(current)

      http_get = fn _url ->
        body =
          :json.encode(%{
            "tag_name" => "v#{next_version}",
            "assets" => [
              %{
                "name" => "sev_macos_arm64",
                "browser_download_url" => "https://example.com/sev"
              }
            ]
          })

        {:ok, IO.iodata_to_binary(body)}
      end

      capture_io(fn ->
        assert {:error, :binary_not_found} =
                 Updater.run(
                   http_get: http_get,
                   binary_path: nil,
                   arch: "aarch64-apple-darwin24.3.0"
                 )
      end)
    end

    test "writes to the Burrito wrapper path when __BURRITO_BIN_PATH is set" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      wrapper_path = Path.join(tmp_dir, "sev")
      File.write!(wrapper_path, "old-wrapper")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      original = System.get_env("__BURRITO_BIN_PATH")

      try do
        System.put_env("__BURRITO_BIN_PATH", wrapper_path)

        http_get = fn url ->
          if String.contains?(url, "api.github.com") do
            body =
              :json.encode(%{
                "tag_name" => "v99.0.0",
                "assets" => [
                  %{
                    "name" => "sev_macos_arm64",
                    "browser_download_url" => "https://example.com/sev"
                  }
                ]
              })

            {:ok, IO.iodata_to_binary(body)}
          else
            {:ok, "new-binary-content"}
          end
        end

        capture_io(fn ->
          assert Updater.run(
                   http_get: http_get,
                   arch: "aarch64-apple-darwin24.3.0",
                   plist_path: Path.join(tmp_dir, "test.plist")
                 ) == :ok
        end)

        assert File.read!(wrapper_path) == "new-binary-content"
      after
        if original,
          do: System.put_env("__BURRITO_BIN_PATH", original),
          else: System.delete_env("__BURRITO_BIN_PATH")
      end
    end

    test "rewrites plist after successful update" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      binary_path = Path.join(tmp_dir, "sev")
      plist_path = Path.join(tmp_dir, "com.severance.daemon.plist")
      File.write!(binary_path, "old-binary")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      http_get = fn url ->
        if String.contains?(url, "api.github.com") do
          body =
            :json.encode(%{
              "tag_name" => "v99.0.0",
              "assets" => [
                %{
                  "name" => "sev_macos_arm64",
                  "browser_download_url" => "https://example.com/sev"
                }
              ]
            })

          {:ok, IO.iodata_to_binary(body)}
        else
          {:ok, "new-binary-content"}
        end
      end

      capture_io(fn ->
        assert Updater.run(
                 http_get: http_get,
                 binary_path: binary_path,
                 arch: "aarch64-apple-darwin24.3.0",
                 plist_path: plist_path
               ) == :ok
      end)

      plist_content = File.read!(plist_path)
      assert plist_content =~ binary_path
      assert plist_content =~ "com.severance.daemon"
    end

    test "skips plist rewrite when no plist exists" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      binary_path = Path.join(tmp_dir, "sev")
      plist_path = Path.join(tmp_dir, "com.severance.daemon.plist")
      File.write!(binary_path, "old-binary")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      http_get = fn url ->
        if String.contains?(url, "api.github.com") do
          body =
            :json.encode(%{
              "tag_name" => "v99.0.0",
              "assets" => [
                %{
                  "name" => "sev_macos_arm64",
                  "browser_download_url" => "https://example.com/sev"
                }
              ]
            })

          {:ok, IO.iodata_to_binary(body)}
        else
          {:ok, "new-binary-content"}
        end
      end

      capture_io(fn ->
        assert Updater.run(
                 http_get: http_get,
                 binary_path: binary_path,
                 arch: "aarch64-apple-darwin24.3.0"
               ) == :ok
      end)

      refute File.exists?(plist_path)
    end

    test "sets executable permission on updated binary" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      binary_path = Path.join(tmp_dir, "sev")
      File.write!(binary_path, "old-binary")

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      http_get = fn url ->
        if String.contains?(url, "api.github.com") do
          body =
            :json.encode(%{
              "tag_name" => "v99.0.0",
              "assets" => [
                %{
                  "name" => "sev_macos_arm64",
                  "browser_download_url" => "https://example.com/sev"
                }
              ]
            })

          {:ok, IO.iodata_to_binary(body)}
        else
          {:ok, "new-binary-content"}
        end
      end

      capture_io(fn ->
        Updater.run(
          http_get: http_get,
          binary_path: binary_path,
          arch: "aarch64-apple-darwin24.3.0",
          plist_path: Path.join(tmp_dir, "test.plist")
        )
      end)

      %{mode: mode} = File.stat!(binary_path)
      assert Bitwise.band(mode, 0o111) != 0
    end
  end

  describe "run/1 daemon restart" do
    test "prompts and restarts when daemon is running and user confirms" do
      {tmp_dir, binary_path, http_get} = update_fixture()
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      stop_called = self()
      restart_called = self()

      output =
        capture_io(fn ->
          assert Updater.run(
                   http_get: http_get,
                   binary_path: binary_path,
                   arch: "aarch64-apple-darwin24.3.0",
                   plist_path: Path.join(tmp_dir, "test.plist"),
                   daemon_running?: fn -> true end,
                   prompt_restart: fn -> true end,
                   stop_daemon: fn ->
                     send(stop_called, :stop_called)
                     :ok
                   end,
                   restart_daemon: fn _path ->
                     send(restart_called, :restart_called)
                     :ok
                   end
                 ) == :ok
        end)

      assert output =~ "Updated to v99.0.0 and restarted"
      assert_received :stop_called
      assert_received :restart_called
    end

    test "skips restart when daemon is running but user declines" do
      {tmp_dir, binary_path, http_get} = update_fixture()
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      output =
        capture_io(fn ->
          assert Updater.run(
                   http_get: http_get,
                   binary_path: binary_path,
                   arch: "aarch64-apple-darwin24.3.0",
                   plist_path: Path.join(tmp_dir, "test.plist"),
                   daemon_running?: fn -> true end,
                   prompt_restart: fn -> false end,
                   stop_daemon: fn -> flunk("stop_daemon should not be called") end,
                   restart_daemon: fn _path -> flunk("restart_daemon should not be called") end
                 ) == :ok
        end)

      assert output =~ "Updated to v99.0.0"
      assert output =~ "Restart the daemon to use the new version"
    end

    test "does not prompt when no daemon is running" do
      {tmp_dir, binary_path, http_get} = update_fixture()
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      output =
        capture_io(fn ->
          assert Updater.run(
                   http_get: http_get,
                   binary_path: binary_path,
                   arch: "aarch64-apple-darwin24.3.0",
                   plist_path: Path.join(tmp_dir, "test.plist"),
                   daemon_running?: fn -> false end,
                   prompt_restart: fn -> flunk("prompt_restart should not be called") end
                 ) == :ok
        end)

      assert output =~ "Updated to v99.0.0"
      refute output =~ "restarted"
      refute output =~ "Restart the daemon"
    end
  end

  defp update_fixture do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    binary_path = Path.join(tmp_dir, "sev")
    File.write!(binary_path, "old-binary")

    http_get = fn url ->
      if String.contains?(url, "api.github.com") do
        body =
          :json.encode(%{
            "tag_name" => "v99.0.0",
            "assets" => [
              %{
                "name" => "sev_macos_arm64",
                "browser_download_url" => "https://example.com/sev"
              }
            ]
          })

        {:ok, IO.iodata_to_binary(body)}
      else
        {:ok, "new-binary-content"}
      end
    end

    {tmp_dir, binary_path, http_get}
  end

  describe "fetch_latest_version/1" do
    setup do
      table = :severance_version_cache

      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      else
        :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
      end

      on_exit(fn ->
        if :ets.whereis(table) != :undefined do
          :ets.delete_all_objects(table)
        end
      end)

      :ok
    end

    test "fetches from GitHub and caches result" do
      http_get = fn _url ->
        body = :json.encode(%{"tag_name" => "v99.0.0", "assets" => []})
        {:ok, IO.iodata_to_binary(body)}
      end

      assert {:ok, "99.0.0"} = Updater.fetch_latest_version(http_get: http_get)

      [{:latest_version, "99.0.0", _ts}] =
        :ets.lookup(:severance_version_cache, :latest_version)
    end

    test "returns cached version when cache is fresh" do
      now = System.system_time(:second)
      :ets.insert(:severance_version_cache, {:latest_version, "1.2.3", now})

      http_get = fn _url -> raise "should not be called" end

      assert {:ok, "1.2.3"} = Updater.fetch_latest_version(http_get: http_get)
    end

    test "fetches fresh when cache is stale (older than 24h)" do
      stale_ts = System.system_time(:second) - 25 * 60 * 60
      :ets.insert(:severance_version_cache, {:latest_version, "1.0.0", stale_ts})

      http_get = fn _url ->
        body = :json.encode(%{"tag_name" => "v2.0.0", "assets" => []})
        {:ok, IO.iodata_to_binary(body)}
      end

      assert {:ok, "2.0.0"} = Updater.fetch_latest_version(http_get: http_get)
    end

    test "returns stale cache on fetch failure" do
      stale_ts = System.system_time(:second) - 25 * 60 * 60
      :ets.insert(:severance_version_cache, {:latest_version, "1.0.0", stale_ts})

      http_get = fn _url -> {:error, :nxdomain} end

      assert {:ok, "1.0.0"} = Updater.fetch_latest_version(http_get: http_get)
    end

    test "returns error on fetch failure with no cache" do
      http_get = fn _url -> {:error, :nxdomain} end

      assert {:error, :nxdomain} = Updater.fetch_latest_version(http_get: http_get)
    end
  end

  describe "create_cache_table/0" do
    test "creates ETS table" do
      table = :severance_version_cache

      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end

      assert :ok = Updater.create_cache_table()
      assert :ets.whereis(table) != :undefined

      # Clean up
      :ets.delete(table)
    end

    test "returns :already_exists when table exists" do
      table = :severance_version_cache

      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
      end

      assert :already_exists = Updater.create_cache_table()
    end
  end

  defp bump_patch(version) do
    [major, minor, patch] = String.split(version, ".")
    "#{major}.#{minor}.#{String.to_integer(patch) + 1}"
  end
end
