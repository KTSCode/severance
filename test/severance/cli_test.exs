defmodule Severance.CLITest do
  use ExUnit.Case, async: true

  alias Severance.CLI

  describe "parse_args/1" do
    test "empty args returns :start" do
      assert CLI.parse_args([]) == :start
    end

    test "otp arg returns :overtime" do
      assert CLI.parse_args(["otp"]) == :overtime
    end

    test "overtime arg returns :overtime" do
      assert CLI.parse_args(["overtime"]) == :overtime
    end

    test "over_time_protocol arg returns :overtime" do
      assert CLI.parse_args(["over_time_protocol"]) == :overtime
    end

    test "shutdown-time flag returns start with custom time" do
      assert CLI.parse_args(["--shutdown-time", "17:00"]) ==
               {:start, shutdown_time: ~T[17:00:00]}
    end

    test "init returns {:init, %{with_tmux?: false}}" do
      assert CLI.parse_args(["init"]) == {:init, %{with_tmux?: false}}
    end

    test "init --with-tmux returns {:init, %{with_tmux?: true}}" do
      assert CLI.parse_args(["init", "--with-tmux"]) == {:init, %{with_tmux?: true}}
    end

    test "update arg returns :update" do
      assert CLI.parse_args(["update"]) == :update
    end

    test "version arg returns :version" do
      assert CLI.parse_args(["version"]) == :version
    end

    test "status arg returns {:status, %{publisher_name: nil, teardown?: false}}" do
      assert CLI.parse_args(["status"]) == {:status, %{publisher_name: nil, teardown?: false}}
    end

    test "log arg returns :log" do
      assert CLI.parse_args(["log"]) == :log
    end

    test "-v flag returns :version" do
      assert CLI.parse_args(["-v"]) == :version
    end

    test "--version flag returns :version" do
      assert CLI.parse_args(["--version"]) == :version
    end

    test "start arg returns :start" do
      assert CLI.parse_args(["start"]) == :start
    end

    test "start with --shutdown-time returns start with opts" do
      assert CLI.parse_args(["start", "--shutdown-time", "16:00"]) ==
               {:start, shutdown_time: ~T[16:00:00]}
    end

    test "start with trailing unknown arg returns error" do
      assert {:error, _msg} = CLI.parse_args(["start", "stop"])
    end

    test "--daemon returns :daemon" do
      assert CLI.parse_args(["--daemon"]) == :daemon
    end

    test "--daemon with --shutdown-time returns daemon with opts" do
      assert CLI.parse_args(["--daemon", "--shutdown-time", "16:00"]) ==
               {:daemon, shutdown_time: ~T[16:00:00]}
    end

    test "unknown command returns error tuple" do
      assert {:error, msg} = CLI.parse_args(["something-else"])
      assert msg =~ "something-else"
    end

    test "invalid --shutdown-time returns error tuple" do
      assert {:error, _msg} = CLI.parse_args(["--shutdown-time", "lol"])
    end

    test "invalid --shutdown-time with out-of-range hours returns error tuple" do
      assert {:error, _msg} = CLI.parse_args(["--shutdown-time", "25:00"])
    end

    test "--help returns :help" do
      assert CLI.parse_args(["--help"]) == :help
    end

    test "subcommand --help returns :help" do
      assert CLI.parse_args(["status", "--help"]) == :help
    end
  end

  describe "usage/0" do
    test "returns a usage string mentioning the binary name" do
      assert CLI.usage() =~ "sev"
    end
  end

  describe "build_daemon_cmd/1" do
    test "builds command with no opts" do
      cmd = CLI.build_daemon_cmd("/usr/local/bin/sev", [])
      assert cmd =~ "/usr/local/bin/sev"
      assert cmd =~ "--daemon"
      assert cmd =~ "</dev/null"
    end

    test "redirects logs under the user's Library/Logs, not /tmp" do
      cmd = CLI.build_daemon_cmd("/usr/local/bin/sev", [])
      home = System.user_home!()

      assert cmd =~ ">>#{home}/Library/Logs/severance.log"
      assert cmd =~ "2>>#{home}/Library/Logs/severance.err"
      refute cmd =~ "/tmp/severance"
    end

    test "includes --shutdown-time when provided" do
      cmd = CLI.build_daemon_cmd("/usr/local/bin/sev", shutdown_time: ~T[16:00:00])
      assert cmd =~ "--daemon"
      assert cmd =~ "--shutdown-time"
      assert cmd =~ "16:00"
    end

    test "shell-escapes the binary path with single quotes" do
      cmd = CLI.build_daemon_cmd("/path with spaces/sev", [])
      assert cmd =~ "'/path with spaces/sev'"
    end

    test "escapes single quotes in binary path" do
      cmd = CLI.build_daemon_cmd("/path'with'quotes/sev", [])
      assert cmd =~ "'/path'\\''with'\\''quotes/sev'"
    end
  end

  describe "start_background/2" do
    test "returns error when binary is not found" do
      assert {:error, msg} = CLI.start_background([], binary: "/nonexistent/sev")
      assert msg =~ "not found"
    end
  end

  describe "await_daemon_ready/1" do
    test "returns error after exhausting attempts when no daemon is running" do
      assert {:error, msg} = CLI.await_daemon_ready(1)
      assert msg =~ "daemon did not start"
    end
  end

  describe "daemon_running?/0" do
    test "returns false with no output when no daemon is running" do
      {io_output, log_output} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            refute CLI.daemon_running?()
          end)
        end)

      assert io_output == ""
      assert log_output == ""
    end
  end

  describe "format_status/2" do
    test "formats running daemon with no update" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Severance v#{Severance.Updater.current_version()}"
      assert output =~ "Status:     running"
      assert output =~ "Overtime:   inactive"
      assert output =~ "Shutdown:   17:00 (42m remaining)"
      assert output =~ "Update:     up to date"
    end

    test "formats running daemon with overtime active" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :overtime,
        phase: :aggressive,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 10
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Overtime:   active"
    end

    test "formats running daemon with update available" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, "99.0.0"}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Update:     v99.0.0 available (run `sev update`)"
    end

    test "shows daemon version, not CLI version, when they differ" do
      daemon = %Severance.Status{
        version: "0.1.0",
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Severance v0.1.0"
      refute output =~ "Severance v#{Severance.Updater.current_version()}"
    end

    test "handles nil shutdown_time without crashing" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: nil,
        minutes_remaining: nil
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Shutdown:   not configured"
    end

    test "formats passed shutdown time" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :overtime,
        phase: :done,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: -30
      }

      update = {:ok, Severance.Updater.current_version()}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Shutdown:   17:00 (passed)"
    end

    test "formats daemon not running with failed update check" do
      output = CLI.format_status({:error, "connection failed"}, {:error, :nxdomain})

      assert output =~ "Severance v#{Severance.Updater.current_version()}"
      assert output =~ "Status:     not running"
      refute output =~ "Overtime:"
      refute output =~ "Shutdown:"
      assert output =~ "Update:     unknown (check failed)"
    end

    test "formats daemon not running with update available" do
      output = CLI.format_status({:error, "connection failed"}, {:ok, "99.0.0"})

      assert output =~ "Status:     not running"
      assert output =~ "Update:     v99.0.0 available (run `sev update`)"
    end

    test "formats daemon not running and up to date" do
      output =
        CLI.format_status(
          {:error, "connection failed"},
          {:ok, Severance.Updater.current_version()}
        )

      assert output =~ "Status:     not running"
      assert output =~ "Update:     up to date"
    end

    test "formats update check failure" do
      daemon = %Severance.Status{
        version: Severance.Updater.current_version(),
        mode: :severance,
        phase: :waiting,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 42
      }

      update = {:error, :nxdomain}

      output = CLI.format_status({:ok, daemon}, update)

      assert output =~ "Update:     unknown (check failed)"
    end
  end

  describe "attach_version/2" do
    test "puts version into a plain map without a :version key" do
      pre_struct_status = %{
        mode: :severance,
        phase: :gentle,
        shutdown_time: ~T[17:00:00],
        minutes_remaining: 12
      }

      result = CLI.attach_version(pre_struct_status, "9.9.9")

      assert result.version == "9.9.9"
      assert result.mode == :severance
    end

    test "overwrites version on a Severance.Status struct" do
      status = %Severance.Status{mode: :severance, phase: :waiting, version: "0.0.0"}

      assert CLI.attach_version(status, "1.2.3").version == "1.2.3"
    end
  end

  describe "parse_args/1 status flags" do
    test "status with no flags returns {:status, %{publisher_name: nil, teardown?: false}}" do
      assert CLI.parse_args(["status"]) == {:status, %{publisher_name: nil, teardown?: false}}
    end

    test "status with publisher name returns publisher_name: :tmux_countdown" do
      assert CLI.parse_args(["status", "tmux_countdown"]) ==
               {:status, %{publisher_name: :tmux_countdown, teardown?: false}}
    end

    test "status with publisher and --teardown returns publisher_name and teardown?" do
      assert CLI.parse_args(["status", "tmux_countdown", "--teardown"]) ==
               {:status, %{publisher_name: :tmux_countdown, teardown?: true}}
    end

    test "status --teardown alone returns publisher_name: nil, teardown?: true" do
      assert CLI.parse_args(["status", "--teardown"]) ==
               {:status, %{publisher_name: nil, teardown?: true}}
    end
  end

  describe "run_status/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sev_cli_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      conf = Path.join(dir, "tmux.conf")
      System.put_env("TMUX_CONF", conf)
      on_exit(fn -> System.delete_env("TMUX_CONF") end)
      on_exit(fn -> File.rm_rf!(dir) end)
      on_exit(fn -> Application.delete_env(:severance, :publishers) end)
      %{conf: conf}
    end

    test "returns :ok with not-running output and update line when daemon is not running" do
      Application.put_env(:severance, :publishers, %{})

      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            assert :ok = CLI.run_status(%{})
          end)
        end)

      assert output =~ "not running"
      assert output =~ "Update:"
    end

    test "--teardown without publisher name prints error to stderr" do
      Application.put_env(:severance, :publishers, %{})

      err =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert :ok = CLI.run_status(%{publisher_name: nil, teardown?: true})
        end)

      assert err =~ "--teardown requires"
    end

    test "unknown publisher name prints error to stderr" do
      Application.put_env(:severance, :publishers, %{})

      err =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert :ok = CLI.run_status(%{publisher_name: :nonexistent, teardown?: false})
        end)

      assert err =~ "unknown publisher"
    end

    test "publisher fn that raises does not crash the CLI" do
      Application.put_env(:severance, :publishers, %{
        boom: %{fn: fn _ -> raise "boom" end, interval_ms: 60_000}
      })

      {result, _err} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert :ok = CLI.run_status(%{publisher_name: :boom, teardown?: false})
          end)
        end)

      assert is_binary(result)
    end

    test "publisher fn that hangs is killed via timeout" do
      Application.put_env(:severance, :publishers, %{
        slow: %{fn: fn _ -> Process.sleep(:infinity) end, interval_ms: 60_000}
      })

      task =
        Task.async(fn ->
          ExUnit.CaptureLog.with_log(fn ->
            ExUnit.CaptureIO.capture_io(:stderr, fn ->
              CLI.run_status(%{publisher_name: :slow, teardown?: false})
            end)
          end)
        end)

      assert {:ok, _} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    end

    test "teardown fn that raises does not crash the CLI" do
      Application.put_env(:severance, :publishers, %{
        bad_td: %{fn: fn _ -> :ok end, teardown: fn -> raise "td boom" end, interval_ms: 60_000}
      })

      ExUnit.CaptureLog.with_log(fn ->
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            assert :ok = CLI.run_status(%{publisher_name: :bad_td, teardown?: true})
          end)
        end)
      end)
    end

    test "publisher with no teardown prints message to stdout" do
      Application.put_env(:severance, :publishers, %{
        no_td: %{fn: fn _ -> :ok end, interval_ms: 60_000}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = CLI.run_status(%{publisher_name: :no_td, teardown?: true})
        end)

      assert output =~ "has no teardown"
    end

    test "wiring block silent when conf already references the var", %{conf: conf} do
      File.write!(conf, ~s|set -ag status-right "\#{@sev_countdown}"\n|)

      Application.put_env(:severance, :publishers, %{
        tmux_countdown: %{fn: fn _ -> :ok end, tmux_var: "countdown", interval_ms: 60_000}
      })

      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            CLI.run_status(%{})
          end)
        end)

      refute output =~ "NOT in"
      refute output =~ "tmux:"
    end

    test "wiring block prints missing vars when conf does not reference them", %{conf: conf} do
      File.write!(conf, "")

      Application.put_env(:severance, :publishers, %{
        tmux_countdown: %{fn: fn _ -> :ok end, tmux_var: "countdown", interval_ms: 60_000}
      })

      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            CLI.run_status(%{})
          end)
        end)

      assert output =~ "@sev_countdown NOT in"
    end

    test "wiring block silent when no publisher has :tmux_var", %{conf: conf} do
      File.write!(conf, "")

      Application.put_env(:severance, :publishers, %{
        file_writer: %{fn: fn _ -> :ok end, interval_ms: 60_000}
      })

      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            CLI.run_status(%{})
          end)
        end)

      refute output =~ "tmux:"
      refute output =~ "NOT in"
    end
  end

  describe "run_status/0 (arity-0 backwards compat)" do
    test "returns :ok with not-running output and update line when daemon is not running" do
      on_exit(fn -> Application.delete_env(:severance, :publishers) end)
      Application.put_env(:severance, :publishers, %{})

      {output, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            assert :ok = CLI.run_status()
          end)
        end)

      assert output =~ "not running"
      assert output =~ "Update:"
    end
  end

  describe "run_log/1" do
    test "prints log file contents" do
      dir = Path.join(System.tmp_dir!(), "severance_test_#{System.unique_integer([:positive])}")
      log_file = Path.join(dir, "activity.log")
      on_exit(fn -> File.rm_rf!(dir) end)

      File.mkdir_p!(dir)
      File.write!(log_file, "2026-04-15T10:00:00 started\n2026-04-15T16:45:00 overtime\n")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log(log_file)
        end)

      assert output =~ "2026-04-15T10:00:00 started"
      assert output =~ "2026-04-15T16:45:00 overtime"
    end

    test "prints message when log file does not exist" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          CLI.run_log("/nonexistent/path/activity.log")
        end)

      assert output =~ "No activity log found"
    end
  end
end
