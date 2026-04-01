defmodule Severance.Init do
  @moduledoc """
  Sets up Severance for first use: creates the config file,
  generates the LaunchAgent plist, and checks tmux readiness.

  Run via `sev init`.
  """

  alias Severance.Config

  @plist_name "com.severance.daemon.plist"

  @doc """
  Runs the full init sequence: config, plist, tmux check.
  Prints results to stdout.
  """
  @spec run() :: :ok
  def run do
    IO.puts("Severance init\n")

    create_config()
    create_plist()
    check_tmux()

    IO.puts("\nDone.")
    :ok
  end

  @doc """
  Creates the default config file if it doesn't already exist.
  """
  @spec create_config() :: :ok
  def create_config do
    if File.exists?(Config.config_path()) do
      IO.puts("[config] Already exists at #{Config.config_path()}")
    else
      Config.write_defaults()
      IO.puts("[config] Created #{Config.config_path()}")
    end

    :ok
  end

  @doc """
  Generates and writes the LaunchAgent plist file.

  Always overwrites — the binary path may have changed.
  """
  @spec create_plist() :: :ok
  def create_plist do
    path = plist_path()
    binary = detect_binary_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, plist_contents(binary))
    IO.puts("[plist] Written to #{path}")
    IO.puts("        Binary: #{binary}")
    IO.puts("        Load:   launchctl load #{path}")
    :ok
  end

  @doc """
  Checks if tmux is available and if `status-right-length` is sufficient
  for the countdown display. Prints guidance but does not modify files.
  """
  @spec check_tmux() :: :ok
  def check_tmux do
    case System.find_executable("tmux") do
      nil ->
        IO.puts("[tmux]  Not found on PATH. Status bar integration won't work.")

      _path ->
        IO.puts("[tmux]  Found on PATH.")
        check_status_right_length()
    end

    :ok
  end

  @doc """
  Generates the LaunchAgent plist XML for the given binary path.
  """
  @spec plist_contents(String.t()) :: String.t()
  def plist_contents(binary_path) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.severance.daemon</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{binary_path}</string>
        <string>start</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <false/>
      <key>StandardOutPath</key>
      <string>/tmp/severance.log</string>
      <key>StandardErrorPath</key>
      <string>/tmp/severance.err</string>
    </dict>
    </plist>
    """
  end

  @doc """
  Detects the path to the `sev` binary. Falls back to the mix project path.
  """
  @spec detect_binary_path() :: String.t()
  def detect_binary_path do
    System.find_executable("sev") || "#{File.cwd!()}/burrito_out/sev"
  end

  defp plist_path do
    Path.join(System.user_home!(), "Library/LaunchAgents/#{@plist_name}")
  end

  defp check_status_right_length do
    case System.cmd("tmux", ["show-option", "-gv", "status-right-length"], stderr_to_stdout: true) do
      {output, 0} -> report_status_right_length(output)
      _ -> IO.puts("        Could not read status-right-length. Is a tmux server running?")
    end
  end

  defp report_status_right_length(output) do
    case output |> String.trim() |> Integer.parse() do
      {length, ""} when length < 80 ->
        IO.puts("        status-right-length is #{length}. Recommend >= 80.")
        IO.puts("        Add to tmux.conf: set -g status-right-length 80")

      {length, ""} ->
        IO.puts("        status-right-length is #{length}. Good.")

      _ ->
        IO.puts("        Could not parse status-right-length.")
    end
  end
end
