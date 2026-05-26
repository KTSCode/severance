defmodule Severance.Init do
  @moduledoc """
  Sets up Severance for first use: creates the config file,
  generates the LaunchAgent plist, and prints tmux.conf instructions
  when publishers with `:tmux_var` are configured.

  Run via `sev init` or `sev init --with-tmux`.
  """

  alias Burrito.Util.Args, as: BurritoArgs
  alias Severance.Config
  alias Severance.StatusPublisher.Tmux.ConfScanner

  @plist_name "com.severance.daemon.plist"

  @doc """
  Runs the full init sequence: config, plist, tmux instructions.
  Prints results to stdout.

  Accepts `with_tmux?: true` to seed a default tmux publisher into the
  generated config file.
  """
  @spec run(map()) :: :ok
  def run(opts \\ %{}) do
    IO.puts("Severance init\n")

    create_config(opts)
    create_plist()
    print_tmux_instructions()

    IO.puts("\nDone.")
    :ok
  end

  @doc """
  Creates the default config file if it doesn't already exist.

  When `with_tmux?: true` is present in opts:
  - Writes the config with the inline tmux publisher if no config exists.
  - Warns and skips if the config already has non-empty `:publishers`.
  - Warns and skips if the config already exists (with empty publishers).
  """
  @spec create_config(map()) :: :ok
  def create_config(opts \\ %{}) do
    with_tmux? = Map.get(opts, :with_tmux?, false)

    cond do
      File.exists?(Config.config_path()) and with_tmux? ->
        warn_existing_when_with_tmux()

      File.exists?(Config.config_path()) ->
        IO.puts("[config] Already exists at #{Config.config_path()}")

      with_tmux? ->
        Config.write_defaults(Config.config_dir(), with_tmux: true)
        IO.puts("[config] Created #{Config.config_path()} with tmux publisher")

      true ->
        Config.write_defaults()
        IO.puts("[config] Created #{Config.config_path()}")
    end

    :ok
  end

  @doc """
  Prints tmux.conf paste instructions for each publisher with a
  `:tmux_var` whose `\#{@sev_<var>}` reference is not already present
  in `~/.tmux.conf` (or `$TMUX_CONF`).

  Silent when no publisher declares `:tmux_var`. Prints
  `tmux.conf already wired.` when all references are present.
  Never writes to disk.
  """
  @spec print_tmux_instructions() :: :ok
  def print_tmux_instructions do
    vars =
      :severance
      |> Application.get_env(:publishers, %{})
      |> Map.values()
      |> Enum.flat_map(fn spec -> List.wrap(spec[:tmux_var]) end)

    case vars do
      [] ->
        :ok

      vars ->
        conf = ConfScanner.read_tmux_conf()
        missing = Enum.reject(vars, &ConfScanner.references?(conf, &1))
        print_paste_block(missing)
    end
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
  Generates the LaunchAgent plist XML for the given binary path.
  """
  @spec plist_contents(String.t()) :: String.t()
  def plist_contents(binary_path) do
    log_dir = Path.join(System.user_home!(), "Library/Logs")

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
      <dict>
        <key>Crashed</key>
        <true/>
      </dict>
      <key>StandardOutPath</key>
      <string>#{log_dir}/severance.log</string>
      <key>StandardErrorPath</key>
      <string>#{log_dir}/severance.err</string>
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

  defp warn_existing_when_with_tmux do
    case Config.read() do
      {:ok, %{publishers: p}} when map_size(p) > 0 ->
        IO.puts("[config] Already has publishers — leaving #{Config.config_path()} unchanged")

      _ ->
        IO.puts("[config] Already exists at #{Config.config_path()} — re-run after removing it to seed --with-tmux")
    end
  end

  defp print_paste_block([]) do
    IO.puts("[tmux]  tmux.conf already wired.")
  end

  defp print_paste_block(missing) do
    lines =
      Enum.map_join(missing, "\n", fn var ->
        ~s|  set -ag status-right "\#{@sev_#{var}}"|
      end)

    IO.puts("""
    [tmux]  Add to your tmux.conf:

      set -g status-right-length 80
    #{lines}

    Then reload: tmux source-file ~/.tmux.conf
    """)
  end

  defp plist_path do
    Path.join(System.user_home!(), "Library/LaunchAgents/#{@plist_name}")
  end
end
