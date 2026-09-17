# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.Transformers.CompileBundle do
  @moduledoc false

  # Final compilation step: fact schema entries and IR rules become a
  # content-hashed `AshRules.Ir.Bundle`, persisted for `__bundle__` and
  # `AshRules.Info`.

  use Spark.Dsl.Transformer

  alias AshRules.Dsl.CombiningRef
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    facts = Transformer.get_entities(dsl_state, [:fact_schema])
    {combining_refs, rules} = partition(Transformer.get_entities(dsl_state, [:rules]))

    bundle =
      AshRules.Ir.Bundle.new(rules, AshRules.Ir.FactSchema.new(facts),
        combining: combining_algorithm(combining_refs)
      )

    {:ok, Transformer.persist(dsl_state, :bundle, bundle)}
  end

  defp partition(entities) do
    Enum.split_with(entities, &match?(%CombiningRef{}, &1))
  end

  defp combining_algorithm([%CombiningRef{algorithm: algorithm} | _rest]), do: algorithm
  defp combining_algorithm([]), do: AshRules.Combining.default()
end
