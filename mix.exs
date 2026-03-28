defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/project.plt"}],
      usage_rules: [file: "CLAUDE.md", usage_rules: []]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Severance.Application, []}
    ]
  end

  defp deps do
    [
      {:tz, "~> 0.28"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.1", only: :dev},
      {:tidewave, "~> 0.2", only: :dev},
      {:propcheck, "~> 1.5", only: [:dev, :test]}
    ]
  end

  defp releases do
    [
      severance: [
        steps: [:assemble],
        include_executables_for: [:unix],
        overlays: ["rel/overlays"]
      ]
    ]
  end
end
