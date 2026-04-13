defmodule Mix.Tasks.Bump do
  @shortdoc "Generate a dependency upgrade prompt for Claude"

  @moduledoc """
  Gathers dependency and runtime version data, then emits a structured
  prompt to stdout for piping into `claude`.

  ## Usage

      mix bump | claude
  """

  use Mix.Task

  @ansi_pattern ~r/\e\[[0-9;]*m/

  @doc """
  Parses `mix hex.outdated` table output into a list of dependency maps.

  Strips ANSI escape codes, skips the header line, and extracts each
  dependency row into `%{name, current, latest, status}`.

  Returns an empty list when all dependencies are up to date.

  ## Examples

      iex> Mix.Tasks.Bump.parse_hex_outdated("All dependencies are up to date")
      []
  """
  @spec parse_hex_outdated(String.t()) :: [
          %{name: String.t(), current: String.t(), latest: String.t(), status: String.t()}
        ]
  def parse_hex_outdated(output) do
    output
    |> strip_ansi()
    |> String.split("\n", trim: true)
    |> Enum.drop_while(&header_line?/1)
    |> Enum.flat_map(&parse_dep_line/1)
  end

  defp strip_ansi(text), do: Regex.replace(@ansi_pattern, text, "")

  defp header_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "Dependency") or trimmed == ""
  end

  defp parse_dep_line(line) do
    parts = String.split(String.trim(line), ~r/\s{2,}/)

    case drop_only_column(parts) do
      [name, current, latest | status_parts] ->
        [%{name: name, current: current, latest: latest, status: Enum.join(status_parts, " ")}]

      _ ->
        []
    end
  end

  defp drop_only_column([name, maybe_only | rest]) when length(rest) >= 3 do
    if version_like?(maybe_only) do
      [name, maybe_only | rest]
    else
      [name | rest]
    end
  end

  defp drop_only_column(parts), do: parts

  @doc """
  Parses `.tool-versions` file content into a map of tool names to versions.

  Skips blank lines and comments (lines starting with `#`).

  ## Examples

      iex> Mix.Tasks.Bump.parse_tool_versions("erlang 28.2\\nzig 0.15.2\\n")
      %{"erlang" => "28.2", "zig" => "0.15.2"}
  """
  @spec parse_tool_versions(String.t()) :: %{String.t() => String.t()}
  def parse_tool_versions(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reject(&blank_or_comment?/1)
    |> Map.new(&parse_tool_line/1)
  end

  defp blank_or_comment?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp parse_tool_line(line) do
    [tool, version] = String.split(String.trim(line), " ", parts: 2)
    {tool, version}
  end

  @doc """
  Normalizes `asdf latest <tool>` output into a version tuple.

  Returns `{:ok, version}` for a valid version string, or
  `{:error, :unavailable}` for empty or error output.

  ## Examples

      iex> Mix.Tasks.Bump.parse_latest_runtime("28.3\\n")
      {:ok, "28.3"}

      iex> Mix.Tasks.Bump.parse_latest_runtime("")
      {:error, :unavailable}
  """
  @spec parse_latest_runtime(String.t()) :: {:ok, String.t()} | {:error, :unavailable}
  def parse_latest_runtime(output) do
    trimmed = String.trim(output)

    if trimmed == "" or not version_like?(trimmed) do
      {:error, :unavailable}
    else
      {:ok, trimmed}
    end
  end

  defp version_like?(string), do: Regex.match?(~r/^\d+[\.\d\-\w]*$/, string)

  @doc """
  Compares current and latest runtime version maps, returning a list of
  updates where the versions differ.

  Only includes tools present in both maps.

  ## Examples

      iex> Mix.Tasks.Bump.runtime_updates(%{"erlang" => "28.2"}, %{"erlang" => "28.2"})
      []
  """
  @spec runtime_updates(%{String.t() => String.t()}, %{String.t() => String.t()}) :: [
          %{tool: String.t(), current: String.t(), latest: String.t()}
        ]
  def runtime_updates(current, latest) do
    current
    |> Enum.filter(fn {tool, version} ->
      Map.has_key?(latest, tool) and latest[tool] != version
    end)
    |> Enum.map(fn {tool, version} ->
      %{tool: tool, current: version, latest: latest[tool]}
    end)
  end

  @doc """
  Formats a list of outdated dependency maps as a markdown table.

  Returns a human-readable message when the list is empty.
  """
  @spec format_outdated_table([%{name: String.t(), current: String.t(), latest: String.t(), status: String.t()}]) ::
          String.t()
  def format_outdated_table([]), do: "All dependencies are up to date."

  def format_outdated_table(deps) do
    header = "| Package | Current | Latest | Status |"
    separator = "|---|---|---|---|"

    rows =
      Enum.map(deps, fn %{name: name, current: current, latest: latest, status: status} ->
        "| #{name} | #{current} | #{latest} | #{status} |"
      end)

    Enum.join([header, separator | rows], "\n")
  end

  @doc """
  Formats a list of runtime update maps as a markdown table.

  Returns a human-readable message when the list is empty.
  """
  @spec format_runtime_table([%{tool: String.t(), current: String.t(), latest: String.t()}]) ::
          String.t()
  def format_runtime_table([]), do: "All runtimes are at latest versions."

  def format_runtime_table(updates) do
    header = "| Tool | Current | Latest |"
    separator = "|---|---|---|"

    rows =
      Enum.map(updates, fn %{tool: tool, current: current, latest: latest} ->
        "| #{tool} | #{current} | #{latest} |"
      end)

    Enum.join([header, separator | rows], "\n")
  end

  @doc """
  Assembles the full upgrade prompt from a gathered data map.

  Expects keys: `:outdated_table`, `:runtime_table`, `:mix_exs`,
  `:mix_lock`, and `:config_files` (list of `{path, content}` tuples).
  """
  @spec build_prompt(%{
          outdated_table: String.t(),
          runtime_table: String.t(),
          mix_exs: String.t(),
          mix_lock: String.t(),
          config_files: [{String.t(), String.t()}]
        }) :: String.t()
  def build_prompt(%{} = data) do
    sections = [
      "# Outdated Dependencies\n\n#{data.outdated_table}",
      "# Runtime Versions\n\n#{data.runtime_table}",
      "# mix.exs\n\n```elixir\n#{data.mix_exs}\n```",
      "# mix.lock\n\n```elixir\n#{data.mix_lock}\n```"
    ]

    config_sections =
      Enum.map(data.config_files, fn {path, content} ->
        "# #{path}\n\n```elixir\n#{content}\n```"
      end)

    instructions = """
    # Instructions

    Update dependencies and runtimes based on the data above.

    - Update one dependency at a time
    - Run `mix quality` between each update to verify nothing breaks
    - If an update fails quality checks, revert it and:
      1. Write a spec to `docs/specs/` describing the failure
      2. Add a TODO to the README linking to the spec
    - For runtime updates, edit `.tool-versions` and verify with `mix quality`
    """

    Enum.join(sections ++ config_sections ++ [String.trim(instructions)], "\n\n")
  end

  @impl Mix.Task
  def run(_args) do
    mix_exs =
      case File.read("mix.exs") do
        {:ok, content} ->
          content

        {:error, _} ->
          stderr("mix.exs not found — aborting.")
          exit({:shutdown, 1})
      end

    mix_lock = read_or_warn("mix.lock", "mix.lock not found")
    tool_versions_content = read_or_warn(".tool-versions", ".tool-versions not found")

    outdated_output = gather_hex_outdated()
    deps = parse_hex_outdated(outdated_output)
    outdated_table = format_outdated_table(deps)

    current_runtimes = parse_tool_versions(tool_versions_content)
    latest_runtimes = gather_latest_runtimes(current_runtimes)
    updates = runtime_updates(current_runtimes, latest_runtimes)
    runtime_table = format_runtime_table(updates)

    config_files = gather_config_files()

    data = %{
      outdated_table: outdated_table,
      runtime_table: runtime_table,
      mix_exs: mix_exs,
      mix_lock: mix_lock,
      config_files: config_files
    }

    IO.puts(build_prompt(data))
  end

  defp read_or_warn(path, message) do
    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        stderr(message)
        ""
    end
  end

  defp gather_hex_outdated do
    {output, _} = System.cmd("mix", ["hex.outdated"], stderr_to_stdout: true)
    output
  end

  defp gather_latest_runtimes(current_runtimes) do
    case find_asdf() do
      nil ->
        stderr("asdf not found — skipping runtime version checks")
        %{}

      asdf ->
        current_runtimes
        |> Map.keys()
        |> Map.new(fn tool -> {tool, fetch_latest_version(asdf, tool)} end)
        |> Enum.reject(fn {_tool, version} -> is_nil(version) end)
        |> Map.new()
    end
  end

  defp fetch_latest_version(asdf, tool) do
    case System.cmd(asdf, ["latest", tool], stderr_to_stdout: true) do
      {output, 0} ->
        case parse_latest_runtime(output) do
          {:ok, version} -> version
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp find_asdf do
    System.find_executable("asdf") || homebrew_asdf()
  end

  defp homebrew_asdf do
    path = "/opt/homebrew/bin/asdf"
    if File.exists?(path), do: path
  end

  defp gather_config_files do
    "config/*.exs"
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      case File.read(path) do
        {:ok, content} -> {path, content}
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp stderr(msg), do: IO.puts(:stderr, msg)
end
