# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.MixProject do
  use Mix.Project

  @version "0.1.0"

  @description """
  Compliance rules as data: a Spark DSL compiling to a serializable rule IR with a
  content-hashed bundle, an outcome lattice with XACML-derived combining, a pure
  direct evaluator, and an optional Wongi.Engine adapter behind one behaviour.
  """

  def project do
    [
      app: :ash_rules,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      docs: &docs/0,
      description: @description,
      package: package(),
      source_url: "https://github.com/lukegalea/ash_rules",
      homepage_url: "https://github.com/lukegalea/ash_rules",
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The library owns no supervision tree and no storage. `:crypto` is used for
  # the bundle content hash (SHA-256 over canonical JSON).
  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp package do
    [
      name: :ash_rules,
      licenses: ["MIT"],
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      files: ~w(lib documentation CHANGELOG.md LICENSE README.md usage-rules.md
        mix.exs .formatter.exs),
      links: %{
        "GitHub" => "https://github.com/lukegalea/ash_rules"
      }
    ]
  end

  defp deps do
    [
      # The DSL machinery. Compile-time only: the compiled artifact is plain
      # data (the IR bundle), never a live DSL state.
      {:spark, "~> 2.0", runtime: false},
      {:ash, "~> 3.0"},
      # Canonical JSON for the bundle content hash and the wire codec.
      {:jason, "~> 1.2"},
      # Optional Rete engine behind `AshRules.Evaluator.Wongi`. The direct
      # evaluator is the default and has no dependency on this; hosts that do
      # not pull wongi_engine get an adapter stub returning
      # `{:error, :wongi_not_available}` instead of a module that cannot load.
      {:wongi_engine, "~> 0.9", optional: true},
      # dev/test only — except stream_data, which ash itself requires in all
      # environments, so restricting it here would diverge the dependency.
      {:stream_data, "~> 1.1"},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/rules-and-fact-schemas.md",
        "documentation/topics/evaluators.md",
        "documentation/topics/what-it-refuses.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r'documentation/topics'
      ],
      groups_for_modules: [
        DSL: [AshRules, AshRules.Dsl, AshRules.Info],
        "Rule IR": [~r/AshRules\.Ir/],
        Evaluation: [
          AshRules.Evaluator,
          ~r/AshRules\.Evaluator/,
          AshRules.Result,
          ~r/AshRules\.Result/,
          AshRules.Outcome,
          AshRules.Combining,
          AshRules.Facts
        ],
        Internals: ~r/.*/
      ]
    ]
  end

  defp aliases do
    [
      credo: "credo --strict",
      test: ["test"]
    ]
  end
end
