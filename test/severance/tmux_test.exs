defmodule Severance.TmuxTest do
  use ExUnit.Case, async: true

  alias Severance.Tmux

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
    test "returns cyan prefix for waiting phase with hours" do
      result = Tmux.countdown_status(600, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev 10h #[default]original"
    end

    test "returns cyan prefix for waiting phase with minutes when under an hour" do
      result = Tmux.countdown_status(45, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev 45m #[default]original"
    end

    test "returns cyan prefix for waiting phase showing exact hour boundary" do
      result = Tmux.countdown_status(60, :waiting, "original")
      assert result == "#[fg=colour51,bold] sev 1h #[default]original"
    end

    test "returns yellow prefix for gentle phase" do
      result = Tmux.countdown_status(25, :gentle, "original")
      assert result == "#[fg=colour226,bold] sev 25m #[default]original"
    end

    test "returns red blinking prefix for aggressive phase" do
      result = Tmux.countdown_status(10, :aggressive, "original")
      assert result == "#[fg=colour196,bold,blink] sev 10m #[default]original"
    end

    test "returns red blinking prefix for final phase" do
      result = Tmux.countdown_status(3, :final, "original")
      assert result == "#[fg=colour196,bold,blink] sev 3m #[default]original"
    end
  end

  describe "format_remaining/1" do
    test "shows whole hours when at or above 60 minutes" do
      assert Tmux.format_remaining(60) == "1h"
      assert Tmux.format_remaining(120) == "2h"
      assert Tmux.format_remaining(600) == "10h"
    end

    test "rounds down partial hours" do
      assert Tmux.format_remaining(119) == "1h"
      assert Tmux.format_remaining(61) == "1h"
    end

    test "shows minutes when under an hour" do
      assert Tmux.format_remaining(59) == "59m"
      assert Tmux.format_remaining(1) == "1m"
      assert Tmux.format_remaining(0) == "0m"
    end
  end
end
