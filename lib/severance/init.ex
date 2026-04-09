defmodule Severance.Init do
  @moduledoc """
  Sets up Severance for first use: creates the config file,
  generates the LaunchAgent plist, and checks tmux readiness.

  Run via `sev init`.
  """

  alias Burrito.Util.Args, as: BurritoArgs
  alias Severance.Config

  @plist_name "com.severance.daemon.plist"

  @doc """
  Runs the full init sequence: config, plist, sudoers, tmux check.
  Prints results to stdout.
  """
  @spec run() :: :ok
  def run do
    IO.puts("Severance init\n")

    create_config()
    create_plist()
    check_tmux()
    setup_sudoers()

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
        <string>--daemon</string>
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
  Detects the path to the `sev` binary.

  Prefers the Burrito wrapper path when running inside a Burrito-wrapped
  binary. Falls back to `System.find_executable/1` or the mix project
  build output path.
  """
  @spec detect_binary_path() :: String.t()
  def detect_binary_path do
    case BurritoArgs.get_bin_path() do
      path when is_binary(path) -> path
      :not_in_burrito -> System.find_executable("sev") || "#{File.cwd!()}/burrito_out/sev"
    end
  end

  @doc """
  Returns the sudoers file content granting passwordless shutdown
  for the given username.
  """
  @spec sudoers_content(String.t()) :: String.t()
  def sudoers_content(username) do
    "#{username} ALL = NOPASSWD: /sbin/shutdown\n"
  end

  @doc """
  Returns true if the current user has passwordless sudo access
  to `/sbin/shutdown`.
  """
  @spec sudoers_configured?() :: boolean()
  def sudoers_configured? do
    case File.read("/etc/sudoers.d/severance") do
      {:ok, content} ->
        username = System.get_env("USER")
        String.contains?(content, "#{username} ALL = NOPASSWD: /sbin/shutdown")

      {:error, _} ->
        false
    end
  end

  defp setup_sudoers do
    if sudoers_configured?() do
      IO.puts("[sudo]  Passwordless shutdown already configured.")
    else
      IO.puts("[sudo]  Configuring passwordless shutdown...")
      install_sudoers()
    end

    :ok
  end

  defp install_sudoers do
    username = System.get_env("USER")
    content = sudoers_content(username)
    tmp = "/tmp/severance_sudoers"

    File.write!(tmp, content)

    with {_, 0} <- System.cmd("visudo", ["-cf", tmp], stderr_to_stdout: true),
         {_, 0} <- System.cmd("sudo", ["cp", tmp, "/etc/sudoers.d/severance"], stderr_to_stdout: true),
         {_, 0} <- System.cmd("sudo", ["chmod", "0440", "/etc/sudoers.d/severance"], stderr_to_stdout: true) do
      File.rm(tmp)
      IO.puts("[sudo]  Passwordless shutdown configured.")
    else
      {output, _code} ->
        File.rm(tmp)
        IO.puts("[sudo]  Failed: #{String.trim(output)}")
    end
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
