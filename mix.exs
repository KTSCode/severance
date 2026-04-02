defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.2.2",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
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
      {:tidewave, "~> 0.2", only: :dev},
      {:burrito, "~> 1.5"}
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
