defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.21.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix]
      ],
      usage_rules: [file: "AGENTS.md", usage_rules: []],
      versioning: [
        tag_prefix: "v",
        commit_msg: "v%s",
        annotate: true,
        annotation: "Release %s"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {Severance.Application, []}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2", only: :dev},
      {:burrito, "~> 1.5.0"},
      {:cli_mate, "~> 0.10"},
      {:doctor, "~> 0.23", only: :dev},
      {:ex_quality, "~> 0.13", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.3", only: :test},
      {:mix_version, "~> 2.5", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.8", only: :dev},
      {:bandit, "~> 1.12", only: :dev}
    ]
  end

  defp aliases do
    [
      tag: &tag_release/1,
      tidewave: "run --no-halt -e '{:ok, _} = Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end

  defp tag_release(args) do
    artifact_dir = check_release_preconditions!()
    Mix.Task.run("changelog.finalize", args)
    Mix.Task.run("version", args)
    {tag, 0} = System.cmd("git", ["describe", "--tags", "--abbrev=0"])
    tag = String.trim(tag)
    {_, 0} = System.cmd("git", ["push", "--atomic", "origin", "HEAD", tag])

    {_, 0} =
      System.cmd(
        "gh",
        ["release", "create", tag, "--notes-from-tag"] ++
          Path.wildcard(Path.join(artifact_dir, "sev_macos_*"))
      )

    Mix.shell().info("Tagged #{tag} and published the smoked release binaries.")
  end

  defp check_release_preconditions! do
    {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    branch = String.trim(branch)
    if branch != "main", do: Mix.raise("Must be on main branch (currently on #{branch})")

    {status, 0} = System.cmd("git", ["status", "--porcelain"])
    if status != "", do: Mix.raise("Uncommitted changes detected. Commit or stash them first.")

    {_, 0} = System.cmd("git", ["fetch", "origin", "main"])
    {local, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {remote, 0} = System.cmd("git", ["rev-parse", "origin/main"])
    if String.trim(local) != String.trim(remote), do: Mix.raise("Local main is behind or ahead of origin/main.")

    check_ci_release_build!(String.trim(local))
  end

  # Dispatches release.yml on CI, waits for it, downloads the built binary
  # and smokes it locally. Local main equals origin/main at this point, so
  # the dispatch builds exactly the code being tagged. Refusing to tag on
  # any failure here is the point: a tag must never outrun a proven release.
  # Polling is filtered to this exact commit + workflow_dispatch so a
  # concurrent run (another dispatch, a stray tag push) can't get smoked
  # and published in place of this one.
  defp check_ci_release_build!(sha) do
    ensure_gh!()
    previous = latest_release_run_id(sha)

    Mix.shell().info("Dispatching release.yml dry-run on CI...")
    {_, 0} = System.cmd("gh", ["workflow", "run", "release.yml", "--ref", "main"])

    run_id = await_new_release_run(sha, previous, 30)
    Mix.shell().info("Watching CI run #{run_id}...")

    case System.cmd("gh", ["run", "watch", run_id, "--exit-status"], into: IO.stream()) do
      {_, 0} -> smoke_ci_artifact!(run_id)
      {_, code} -> Mix.raise("CI release build failed (gh run watch exit #{code}). Not tagging.")
    end
  end

  defp ensure_gh! do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> Mix.raise("gh is not authenticated — the CI release gate cannot run. Not tagging.\n#{out}")
    end
  rescue
    ErlangError ->
      Mix.raise("gh CLI not found — the CI release gate cannot run. Install gh, then re-run mix tag.")
  end

  defp latest_release_run_id(sha) do
    {out, 0} =
      System.cmd("gh", [
        "run",
        "list",
        "--workflow=release.yml",
        "--commit",
        sha,
        "--event",
        "workflow_dispatch",
        "--limit",
        "1",
        "--json",
        "databaseId"
      ])

    case Regex.run(~r/"databaseId":\s*(\d+)/, out) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp await_new_release_run(_sha, _previous, 0) do
    Mix.raise("Dispatched release.yml but no new CI run appeared. Not tagging.")
  end

  defp await_new_release_run(sha, previous, attempts_left) do
    Process.sleep(2_000)

    case latest_release_run_id(sha) do
      nil -> await_new_release_run(sha, previous, attempts_left - 1)
      ^previous -> await_new_release_run(sha, previous, attempts_left - 1)
      run_id -> run_id
    end
  end

  defp smoke_ci_artifact!(run_id) do
    dir = Path.join(System.tmp_dir!(), "sev_release_gate_#{run_id}")
    File.rm_rf!(dir)

    {_, 0} = System.cmd("gh", ["run", "download", run_id, "-n", "burrito_out", "-D", dir])

    {arch, 0} = System.cmd("uname", ["-m"])
    binary = if String.trim(arch) == "arm64", do: "sev_macos_arm64", else: "sev_macos_x86"
    script = Path.expand("bin/checks/release_smoke.sh")

    Mix.shell().info("Smoking CI artifact #{binary}...")

    case System.cmd(script, [Path.join(dir, binary)], into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("CI artifact smoke passed.")
        dir

      {_, 2} ->
        Mix.raise(
          "Release smoke was skipped (see output above — likely the local sev daemon is running). " <>
            "Stop it (launchctl bootout gui/$UID/com.severance.daemon), then re-run mix tag."
        )

      {_, code} ->
        Mix.raise("CI artifact failed the release smoke (exit #{code}). Not tagging.")
    end
  end

  defp releases do
    [
      sev: [
        steps: [:assemble, &Burrito.wrap/1],
        include_executables_for: [:unix],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
