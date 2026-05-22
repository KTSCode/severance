defmodule Severance.StatusPublisher.Tmux.PanesTest do
  use ExUnit.Case, async: true

  alias Severance.StatusPublisher.Tmux.Panes

  describe "parse_stale_panes/2" do
    test "returns panes with activity older than threshold" do
      now = System.os_time(:second)
      old = now - 20 * 60
      recent = now - 5 * 60

      raw_output =
        "dev:editor.0\t/Users/kyle/project1\t#{old}\n" <>
          "dev:server.1\t/Users/kyle/project1\t#{recent}\n" <>
          "notes:main.0\t/Users/kyle/notes\t#{old}\n"

      stale = Panes.parse_stale_panes(raw_output, now - 15 * 60)

      assert length(stale) == 2
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
      assert %{pane: "notes:main.0", path: "/Users/kyle/notes"} in stale
    end

    test "returns empty list when all panes are active" do
      now = System.os_time(:second)
      recent = now - 5 * 60

      raw_output = "dev:editor.0\t/Users/kyle/project1\t#{recent}\n"

      assert Panes.parse_stale_panes(raw_output, now - 15 * 60) == []
    end

    test "handles empty tmux output" do
      now = System.os_time(:second)
      assert Panes.parse_stale_panes("", now - 15 * 60) == []
    end

    test "skips malformed lines" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "bad line\ndev:editor.0\t/Users/kyle/project1\t#{old}\n"

      stale = Panes.parse_stale_panes(raw_output, now - 15 * 60)
      assert length(stale) == 1
      assert %{pane: "dev:editor.0", path: "/Users/kyle/project1"} in stale
    end

    test "handles paths with spaces" do
      now = System.os_time(:second)
      old = now - 20 * 60

      raw_output = "dev:editor.0\t/Users/kyle/my project\t#{old}\n"

      stale = Panes.parse_stale_panes(raw_output, now - 15 * 60)
      assert [%{pane: "dev:editor.0", path: "/Users/kyle/my project"}] = stale
    end
  end
end
