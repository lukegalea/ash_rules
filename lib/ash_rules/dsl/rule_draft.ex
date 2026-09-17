# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.RuleDraft do
  @moduledoc false

  # The rule entity's build target. Spark stores nested entities under struct
  # field names (`applicability`, `failure_conditions`, `outcomes`), which are
  # DSL shapes, not IR shapes — `AshRules.Dsl.Build.rule/1` compiles this
  # draft into an `AshRules.Ir.Rule` inside the entity transform, so the rest
  # of the package (transformer, verifiers, evaluators) only ever sees IR.

  defstruct [
    :name,
    :id,
    :revision,
    :severity,
    :message,
    :remediation_ref,
    :source,
    applicability: [],
    failure_conditions: [],
    outcomes: [],
    controls: [],
    evidence: [],
    opts: [],
    __spark_metadata__: nil
  ]

  @type t() :: %__MODULE__{
          name: String.t(),
          id: String.t() | nil,
          revision: String.t() | nil,
          severity: AshRules.Ir.Rule.severity() | nil,
          message: String.t() | nil,
          remediation_ref: String.t() | nil,
          source: String.t() | nil,
          applicability: [AshRules.Dsl.PredicateRef.t()],
          failure_conditions: [AshRules.Dsl.PredicateRef.t()],
          outcomes: [AshRules.Ir.OutcomeDeclaration.t()],
          controls: [String.t()],
          evidence: [String.t()],
          opts: keyword()
        }
end
