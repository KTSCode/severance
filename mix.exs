defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.9.0",
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
      usage_rules: [file: "AGENTS.md", usage_rules: []]
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
      {:mimic, "~> 1.10", only: :test},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave: "run --no-halt -e '{:ok, _} = Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
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
