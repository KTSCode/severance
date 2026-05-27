defmodule Severance.StatusPublisher.Tmux.ConfScannerTest do
  use ExUnit.Case, async: false

  alias Severance.StatusPublisher.Tmux.ConfScanner

  setup do
    dir = Path.join(System.tmp_dir!(), "sev_conf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    conf = Path.join(dir, "tmux.conf")
    System.put_env("TMUX_CONF", conf)
    on_exit(fn -> System.delete_env("TMUX_CONF") end)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{conf: conf}
  end

  test "missing file returns :missing", %{conf: conf} do
    File.rm(conf)
    assert ConfScanner.read_tmux_conf() == :missing
    refute ConfScanner.references?(:missing, "countdown")
  end

  test "matches \#{@sev_<var>} on a non-comment line", %{conf: conf} do
    File.write!(conf, ~s|set -ag status-right "\#{@sev_countdown}"\n|)
    assert {:ok, _} = result = ConfScanner.read_tmux_conf()
    assert ConfScanner.references?(result, "countdown")
  end

  test "ignores matches inside a comment line", %{conf: conf} do
    File.write!(conf, ~s|# set -ag status-right "\#{@sev_countdown}"\n|)
    result = ConfScanner.read_tmux_conf()
    refute ConfScanner.references?(result, "countdown")
  end

  test "matches multi-line file with mixed content", %{conf: conf} do
    File.write!(conf, """
    set -g status-right-length 80
    set -ag status-right "\#{@sev_battery}"
    """)

    result = ConfScanner.read_tmux_conf()
    assert ConfScanner.references?(result, "battery")
    refute ConfScanner.references?(result, "countdown")
  end

  test "returns false for {:error, _} result", %{conf: _conf} do
    refute ConfScanner.references?({:error, :enoent}, "countdown")
  end
end
