# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Result.Requirement do
  @moduledoc """
  The evaluation result for one rule of a bundle.

  This is the provenance unit: which rule revision produced the outcome, under
  which gap/control reference, from which consumed facts. `consumed_facts` are
  the working-memory facts the match read (absences resolved as `:false` appear
  as their synthesized triple — the result says what the engine actually
  believed); `probed_facts` are the ground triples checked for absence by
  `:neg` clauses or by `missing: :false` semantics.
  """

  defstruct [
    :rule_id,
    :rule_revision,
    :severity,
    :gap,
    :outcome,
    :message,
    :bindings,
    :consumed_facts,
    :probed_facts,
    :missing_facts
  ]

  @type t() :: %__MODULE__{
          rule_id: String.t(),
          rule_revision: String.t(),
          severity: AshRules.Ir.Rule.severity() | nil,
          gap: String.t() | nil,
          outcome: AshRules.Outcome.t(),
          message: String.t() | nil,
          bindings: [map()],
          consumed_facts: [AshRules.Facts.triple()],
          probed_facts: [AshRules.Facts.triple()],
          missing_facts: [AshRules.Facts.triple()]
        }
end
