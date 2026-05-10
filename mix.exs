defmodule Davy.MixProject do
  use Mix.Project

  @moduledoc """
  A Plug-based WebDAV server library for Elixir.
  """
  @version "0.3.1"
  @source_url "https://harton.dev/james/davy"

  def project do
    [
      aliases: aliases(),
      app: :davy,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      description: @moduledoc,
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :telemetry]
    ]
  end

  defp package do
    [
      maintainers: ["James Harton <james@harton.dev>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => @source_url,
        "Changelog" => "#{@source_url}/src/branch/main/CHANGELOG.md"
      }
    ]
  end

  defp aliases, do: []

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:saxy, "~> 1.6"},
      {:telemetry, "~> 1.0"},

      # dev/test
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:req, "~> 0.5", only: [:dev, :test]},
      {:jason, "~> 1.0", only: [:dev, :test]},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:earmark, "~> 1.4", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.8", only: [:dev, :test]},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false}
    ]
  end
end
