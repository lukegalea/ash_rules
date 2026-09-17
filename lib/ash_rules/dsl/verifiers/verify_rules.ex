# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.Verifiers.VerifyRules do
  @moduledoc false

  # Runs the shared semantic verifiers (`AshRules.Verifier`) over the compiled
  # IR rules. The same checks run at admission for decoded tenant IR, so a
  # refusal is a refusal no matter which door the rules came through.

  use Spark.Dsl.Verifier

  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.Rule
  alias AshRules.Verifier
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    schema =
      dsl_state
      |> Transformer.get_entities([:fact_schema])
      |> FactSchema.new()

    rules =
      dsl_state
      |> Transformer.get_entities([:rules])
      |> Enum.filter(&match?(%Rule{}, &1))

    per_rule_errors =
      Enum.flat_map(rules, fn rule ->
        rule
        |> then(&Verifier.verify_rule(schema, &1))
        |> Enum.map(fn message -> {rule.id, message} end)
      end)

    duplicate_errors = duplicate_id_errors(rules)

    (duplicate_errors ++ per_rule_errors)
    |> raise_first(dsl_state)
  end

  defp duplicate_id_errors(rules) do
    rules
    |> Enum.map(& &1.id)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} ->
      {id,
       "rule #{inspect(id)}: id is declared more than once. " <>
         "Rule ids must be unique — they are the provenance key every finding is filed under"}
    end)
  end

  defp raise_first([], _dsl_state), do: :ok

  defp raise_first([{rule_id, message} | _], dsl_state) do
    raise DslError,
      module: Transformer.get_persisted(dsl_state, :module),
      message: message,
      path: [:rules, rule_id]
  end
end
