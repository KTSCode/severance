defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.12.0",
      elixir: "~> 1.19",
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
      {:usage_rules, "~> 1.1", only: :dev},
      {:burrito, "~> 1.5"},
      {:doctor, "~> 0.22", only: :dev},
      {:ex_quality, "~> 0.6", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.3", only: :test},
      {:mix_version, "~> 2.4", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp aliases do
    [
      tag: &tag_release/1,
      tidewave: "run --no-halt -e '{:ok, _} = Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end

  defp tag_release(args) do
    check_release_preconditions!()
    Mix.Task.run("changelog.finalize", args)
    Mix.Task.run("version", args)
    {tag, 0} = System.cmd("git", ["describe", "--tags", "--abbrev=0"])
    tag = String.trim(tag)
    {_, 0} = System.cmd("git", ["push", "--atomic", "origin", "HEAD", tag])
    Mix.shell().info("Tagged #{tag} and pushed. CI will handle the release.")
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
