defmodule Severance.UpdaterTest do
  use ExUnit.Case, async: true

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
      assert Updater.target_name("aarch64-apple-darwin24.3.0") == "sev_macos_arm64"
    end

    test "returns x86 binary name for x86_64 architecture" do
      assert Updater.target_name("x86_64-apple-darwin24.3.0") == "sev_macos_x86"
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
                   arch: "aarch64-apple-darwin24.3.0"
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
          arch: "aarch64-apple-darwin24.3.0"
        )
      end)

      %{mode: mode} = File.stat!(binary_path)
      assert Bitwise.band(mode, 0o111) != 0
    end
  end

  defp bump_patch(version) do
    [major, minor, patch] = String.split(version, ".")
    "#{major}.#{minor}.#{String.to_integer(patch) + 1}"
  end
end
