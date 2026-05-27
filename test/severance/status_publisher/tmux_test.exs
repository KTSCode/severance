defmodule Severance.StatusPublisher.TmuxTest do
  use ExUnit.Case, async: false

  alias Severance.StatusPublisher.Tmux

  describe "publisher/3" do
    test "builds a map with :fn, :teardown, :tmux_var, :interval_ms" do
      spec = Tmux.publisher("countdown", fn _ -> "x" end)
      assert is_function(spec.fn, 1)
      assert is_function(spec.teardown, 0)
      assert spec.tmux_var == "countdown"
      assert spec.interval_ms == 60_000
    end

    test "honors :interval_ms opt" do
      spec = Tmux.publisher("foo", fn _ -> "y" end, interval_ms: 5_000)
      assert spec.interval_ms == 5_000
    end
  end

  describe "set_var/2 + clear_var/1" do
    test "set_var shells out via the system adapter" do
      Tmux.set_var("countdown", "sev:42m")
      assert_received {:tmux_cmd, ["set", "-gq", "@sev_countdown", "sev:42m"]}
    end

    test "clear_var shells out with empty value" do
      Tmux.clear_var("countdown")
      assert_received {:tmux_cmd, ["set", "-gq", "@sev_countdown", ""]}
    end
  end
end
