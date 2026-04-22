defmodule Severance.TmuxTest do
  use ExUnit.Case, async: false

  alias Severance.Tmux

  defmodule FailingSystem do
    @moduledoc false
    @behaviour Severance.System

    @impl true
    def notify(_title, _message, _sound), do: :ok

    @impl true
    def shutdown_machine, do: :ok

    @impl true
    def tmux_cmd(_args), do: {"no server running", 1}
  end

  describe "parse_stale_panes/2" do
    test "returns panes with activity older than threshold" do
      now = System.os_time(:second)
      old = now - 20 * 60
      recent = now - 5 * 60

      raw_output =
        "dev:editor.0\t/Users/kyle/project1\t#{old}\n" <>
          "dev:server.1\t/Users/kyle/project1\t#{recent}\n" <>
          "notes:main.0\t/Users/kyle/notes\t#{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)

      assert length(stale) == 2
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
      assert %{pane: "notes:main.0", path: "/Users/kyle/notes"} in stale
    end

    test "returns empty list when all panes are active" do
      now = System.os_time(:second)
      recent = now - 5 * 60

      raw_output = "dev:editor.0\t/Users/kyle/project1\t#{recent}\n"

      assert Tmux.parse_stale_panes(raw_output, now - 15 * 60) == []
    end

    test "handles empty tmux output" do
      now = System.os_time(:second)
      assert Tmux.parse_stale_panes("", now - 15 * 60) == []
    end

    test "skips malformed lines" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "bad line\ndev:editor.0\t/Users/kyle/project1\t#{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)
      assert length(stale) == 1
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
    end

    test "handles paths with spaces" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "dev:editor.0\t/Users/kyle/my project\t#{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)
      assert [%{pane: "dev:editor.0", path: "/Users/kyle/my project"}] = stale
    end
  end

  describe "countdown_status/3" do
    test "returns cyan prefix for waiting phase with hours and minutes" do
      result = Tmux.countdown_status(312, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev:5h12m #[default]original"
    end

    test "returns cyan prefix for waiting phase with minutes when under an hour" do
      result = Tmux.countdown_status(45, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev:45m #[default]original"
    end

    test "returns cyan prefix for waiting phase showing exact hour boundary" do
      result = Tmux.countdown_status(60, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev:1h #[default]original"
    end

    test "returns yellow prefix for gentle phase" do
      result = Tmux.countdown_status(25, :gentle, "original")
      assert result == "#[fg=colour226,bold] sev:25m #[default]original"
    end

    test "returns red blinking prefix for aggressive phase" do
      result = Tmux.countdown_status(10, :aggressive, "original")
      assert result == "#[fg=colour196,bold,blink] sev:10m #[default]original"
    end

    test "returns red blinking prefix for final phase" do
      result = Tmux.countdown_status(3, :final, "original")
      assert result == "#[fg=colour196,bold,blink] sev:3m #[default]original"
    end
  end

  describe "capture_status_right/0" do
    test "returns :error when tmux command exits nonzero" do
      original = Application.get_env(:severance, :system_adapter)
      Application.put_env(:severance, :system_adapter, FailingSystem)

      on_exit(fn ->
        if original do
          Application.put_env(:severance, :system_adapter, original)
        else
          Application.delete_env(:severance, :system_adapter)
        end
      end)

      assert Tmux.capture_status_right() == :error
    end

    test "returns {:ok, value} when tmux command succeeds" do
      # Default test adapter returns {"", 0}
      assert Tmux.capture_status_right() == {:ok, ""}
    end
  end

  describe "strip_sev_prefix/1" do
    test "strips a waiting-phase sev banner and returns the original status" do
      wrapped = "#[fg=colour51,bold] sev:5h12m #[default]original"
      assert Tmux.strip_sev_prefix(wrapped) == "original"
    end

    test "strips the escalation blinking prefix" do
      wrapped = "#[fg=colour196,bold,blink] sev:3m #[default]#S | %H:%M"
      assert Tmux.strip_sev_prefix(wrapped) == "#S | %H:%M"
    end

    test "leaves unrelated strings untouched" do
      raw = "#S | %Y-%m-%d %H:%M"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "leaves strings with #[default] but no sev banner untouched" do
      raw = "#[fg=green]branch#[default] | #S"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "leaves user widgets that merely contain sev: untouched" do
      # User has their own widget whose text happens to contain "sev:".
      # Must not be treated as Severance's banner.
      raw = "#[fg=green]sev:prod#[default] | %H:%M"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "leaves a leading user widget with sev: prefix in a non-severance color untouched" do
      # User widget uses its own numeric color (not one Severance emits).
      # The shape is identical to Severance's banner, so a loose match would
      # clobber it. The strict match must leave it alone.
      raw = "#[fg=colour39,bold] sev:prod #[default] | %H:%M"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "leaves a leading sev banner with a non-severance time format untouched" do
      # countdown_status only ever emits format_remaining output (e.g. "25m",
      # "1h", "5h12m"). A widget that looks like a banner but carries
      # arbitrary text must not be stripped.
      raw = "#[fg=colour51,bold] sev:custom #[default]original"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "leaves a banner whose bold+blink flag does not match its color untouched" do
      # Severance only ever pairs ,blink with colour196. A colour51,bold,blink
      # banner is not something countdown_status emits.
      raw = "#[fg=colour51,bold,blink] sev:5m #[default]original"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "only strips at the start of the string" do
      raw = "leading #[fg=colour51,bold] sev:5h12m #[default]original"
      assert Tmux.strip_sev_prefix(raw) == raw
    end

    test "handles empty input" do
      assert Tmux.strip_sev_prefix("") == ""
    end
  end

  describe "format_remaining/1" do
    test "shows hours and minutes when both nonzero" do
      assert Tmux.format_remaining(312) == "5h12m"
      assert Tmux.format_remaining(61) == "1h1m"
      assert Tmux.format_remaining(119) == "1h59m"
    end

    test "omits minutes on exact hour boundary" do
      assert Tmux.format_remaining(60) == "1h"
      assert Tmux.format_remaining(120) == "2h"
      assert Tmux.format_remaining(600) == "10h"
    end

    test "shows minutes only when under an hour" do
      assert Tmux.format_remaining(59) == "59m"
      assert Tmux.format_remaining(1) == "1m"
      assert Tmux.format_remaining(0) == "0m"
    end
  end
end
