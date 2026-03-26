defmodule Severance.MixProject do
  use Mix.Project

  def project do
    [
      app: :severance,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
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
      {:tz, "~> 0.28"}
    ]
  end

  defp releases do
    [
      severance: [
        steps: [:assemble],
        include_executables_for: [:unix]
      ]
    ]
  end
end
