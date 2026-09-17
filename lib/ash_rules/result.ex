# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Result do
  @moduledoc """
  The outcome of evaluating a bundle against a working memory.

  Carries everything an auditor or a projector needs: per-requirement outcomes
  with provenance, the derived (finding) facts, the missing facts, the bundle
  and schema revisions the evaluation pinned, the combining algorithm, the
  overall outcome, and the determinism seed the evaluation ran under.

  The overall outcome is the bundle's combining algorithm applied to the
  requirement outcomes — see `AshRules.Combining`. `unknown` and `error`
  outcomes never collapse to `compliant`; the property suite asserts it.
  """

  alias AshRules.Result.Requirement

  defstruct [
    :bundle_hash,
    :bundle_revision,
    :fact_schema_revision,
    :combining,
    :requirements,
    :derived_facts,
    :missing_facts,
    :overall,
    :evaluator,
    :seed
  ]

  @type t() :: %__MODULE__{
          bundle_hash: String.t(),
          bundle_revision: String.t(),
          fact_schema_revision: String.t(),
          combining: AshRules.Combining.algorithm(),
          requirements: [Requirement.t()],
          derived_facts: [AshRules.Facts.triple()],
          missing_facts: [AshRules.Facts.triple()],
          overall: AshRules.Outcome.t(),
          evaluator: module(),
          seed: term()
        }

  @doc "The fired (asserted-outcome) requirements, in rule order."
  @spec findings(t()) :: [Requirement.t()]
  def findings(%__MODULE__{requirements: requirements}) do
    Enum.filter(requirements, &(&1.outcome not in [:compliant, :not_applicable]))
  end

  @doc "Builds a result from requirements, computing derived/missing facts and the overall outcome."
  @spec new(AshRules.Ir.Bundle.t(), [Requirement.t()], module(), keyword()) :: t()
  def new(%AshRules.Ir.Bundle{} = bundle, requirements, evaluator, opts \\ []) do
    derived_facts =
      requirements
      |> Enum.flat_map(fn requirement ->
        requirement.bindings
        |> Enum.with_index(1)
        |> Enum.map(fn {_bindings, index} ->
          {requirement.rule_id, :finding, index}
        end)
      end)

    missing_facts =
      requirements
      |> Enum.flat_map(& &1.missing_facts)
      |> Enum.uniq()
      |> Enum.sort()

    %__MODULE__{
      bundle_hash: bundle.content_hash,
      bundle_revision: bundle.revision,
      fact_schema_revision: bundle.fact_schema_revision,
      combining: bundle.combining,
      requirements: requirements,
      derived_facts: derived_facts,
      missing_facts: missing_facts,
      overall: AshRules.Combining.combine(bundle.combining, Enum.map(requirements, & &1.outcome)),
      evaluator: evaluator,
      seed: opts[:seed]
    }
  end
end
