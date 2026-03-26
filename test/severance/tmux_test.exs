defmodule Severance.TmuxTest do
  use ExUnit.Case, async: true

  alias Severance.Tmux

  describe "parse_stale_panes/2" do
    test "returns panes with activity older than threshold" do
      now = System.os_time(:second)
      old = now - 20 * 60
      recent = now - 5 * 60

      raw_output =
        "dev:editor.0 /Users/kyle/project1 #{old}\n" <>
          "dev:server.1 /Users/kyle/project1 #{recent}\n" <>
          "notes:main.0 /Users/kyle/notes #{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)

      assert length(stale) == 2
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
      assert %{pane: "notes:main.0", path: "/Users/kyle/notes"} in stale
    end

    test "returns empty list when all panes are active" do
      now = System.os_time(:second)
      recent = now - 5 * 60

      raw_output = "dev:editor.0 /Users/kyle/project1 #{recent}\n"

      assert Tmux.parse_stale_panes(raw_output, now - 15 * 60) == []
    end

    test "handles empty tmux output" do
      now = System.os_time(:second)
      assert Tmux.parse_stale_panes("", now - 15 * 60) == []
    end

    test "skips malformed lines" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "bad line\ndev:editor.0 /Users/kyle/project1 #{old}\n"

      stale = Tmux.parse_stale_panes(raw_output, now - 15 * 60)
      assert length(stale) == 1
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
    end
  end

  describe "countdown_status/3" do
    test "returns yellow prefix for gentle phase" do
      result = Tmux.countdown_status(25, :gentle, "original")
      assert result == "#[fg=colour226,bold] STOP:25m #[default]original"
    end

    test "returns red blinking prefix for aggressive phase" do
      result = Tmux.countdown_status(10, :aggressive, "original")
      assert result == "#[fg=colour196,bold,blink] STOP:10m #[default]original"
    end

    test "returns red blinking prefix for final phase" do
      result = Tmux.countdown_status(3, :final, "original")
      assert result == "#[fg=colour196,bold,blink] STOP:3m #[default]original"
    end
  end
end
