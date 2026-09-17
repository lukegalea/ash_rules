# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl do
  @moduledoc """
  The Spark DSL extension behind `use AshRules`.

  ## Sections

    * `fact_schema` — the fact vocabulary: `fact :name, :type` entries with
      value constraints and absence semantics.
    * `rules` — top-level `rule` declarations with `when_requires`,
      `fails_when` and `outcome` clauses, plus the rule set's `combining`
      algorithm.

  Entities compile to IR structs (`AshRules.Ir.*`) through entity transforms
  and `AshRules.Dsl.Transformers.CompileBundle`, which persists the finished
  `AshRules.Ir.Bundle` for `__bundle__`/`AshRules.Info` to expose. Semantic
  validation runs in `AshRules.Dsl.Verifiers`, which share the checks with
  `AshRules.Ir.decode/1`.
  """

  alias AshRules.Combining
  alias AshRules.Dsl.CombiningRef
  alias AshRules.Dsl.PredicateRef
  alias AshRules.Dsl.RuleDraft
  alias AshRules.Ir.Fact
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate

  @fact %Spark.Dsl.Entity{
    name: :fact,
    target: Fact,
    args: [:name, :type],
    describe: "Declares one predicate of the fact schema.",
    examples: [
      "fact :status, :atom, one_of: [:active, :suspended]",
      "fact :has_valid_kyc, :boolean, missing: :unknown"
    ],
    schema: [
      name: [type: :atom, required: true, doc: "The predicate name."],
      type: [
        type: {:in, Fact.types()},
        required: true,
        doc: "The value type. Fact values and rule predicates are checked against it."
      ],
      one_of: [
        type: {:wrap_list, :atom},
        doc: "For `:atom` facts: the closed vocabulary of allowed values."
      ],
      cardinality: [
        type: {:in, Fact.cardinalities()},
        default: :one,
        doc: "Values per subject-predicate pair. `:one` is the only supported value in 0.1."
      ],
      missing: [
        type: {:in, Fact.missing_values()},
        default: false,
        doc:
          "Absence semantics: `:false` (absence counts as false and is reported), " <>
            "`:unknown` (absence makes probing rules unknown), " <>
            "`:no_fact` (absence is an expected state, behaves as false, not reported)."
      ],
      description: [type: :string, doc: "What the fact means."],
      source: [type: :string, doc: "Where the fact comes from."],
      dependencies: [
        type: {:wrap_list, :atom},
        default: [],
        doc: "Predicates expected alongside this one."
      ],
      sensitive?: [type: :boolean, default: false, doc: "The value is PII or a secret."],
      tenant_scoped?: [type: :boolean, default: false, doc: "Values differ per tenant."]
    ]
  }

  @fact_schema %Spark.Dsl.Section{
    name: :fact_schema,
    describe: "The fact schema: every predicate a rule may probe.",
    entities: [@fact]
  }

  @requires %Spark.Dsl.Entity{
    name: :requires,
    target: PredicateRef,
    args: [:predicate],
    hide: [],
    describe: "One applicability predicate. Normally written via `when_requires`.",
    schema: [
      predicate: [
        type: {:struct, Predicate},
        required: true,
        doc: "A `has/3` or `neg/3` predicate."
      ]
    ]
  }

  @fails %Spark.Dsl.Entity{
    name: :fails,
    target: PredicateRef,
    args: [:predicate],
    describe: "One failure-condition predicate. Normally written via `fails_when`.",
    schema: [
      predicate: [
        type: {:struct, Predicate},
        required: true,
        doc: "A `has/3` or `neg/3` predicate."
      ]
    ]
  }

  @outcome %Spark.Dsl.Entity{
    name: :outcome,
    target: OutcomeDeclaration,
    args: [:outcome],
    describe: "What the rule asserts when its failure conditions all hold.",
    examples: ["outcome :noncompliant, gap: \"kyc.valid_required\""],
    schema: [
      outcome: [
        type: {:in, OutcomeDeclaration.allowed()},
        required: true,
        doc: "The asserted outcome when the rule fires."
      ],
      gap: [
        type: :string,
        doc:
          "The control/gap reference the finding is filed under. Required for " <>
            "`:noncompliant` outcomes — the verifiers refuse an unfiled finding."
      ]
    ]
  }

  @rule %Spark.Dsl.Entity{
    name: :rule,
    target: RuleDraft,
    args: [:name, :opts],
    transform: {AshRules.Dsl.Build, :rule, []},
    imports: [AshRules.Dsl.Predicates],
    describe: "Declares one rule of the rule set.",
    examples: [
      ~s{rule "active regulated customer requires valid KYC",\n  id: "kyc.valid_required",\n  severity: :medium do\n  when_requires has(:customer, :status, :active)\n  fails_when neg(:customer, :has_valid_kyc, true)\n  outcome :noncompliant, gap: "kyc.valid_required"\nend}
    ],
    schema: [
      name: [type: :string, required: true, doc: "The human-readable rule statement."],
      opts: [
        type: :keyword_list,
        default: [],
        doc:
          "The rule's options (`id`, `severity`, `revision`, `message`, " <>
            "`remediation_ref`, `controls`, `evidence`, `source`). Spark routes the " <>
            "trailing keyword list of `rule \"name\", id: ... do` here."
      ],
      id: [
        type: :string,
        doc:
          "The stable identifier findings are filed under. Required — the verifiers refuse a rule without one."
      ],
      severity: [
        type: {:in, AshRules.Ir.Rule.severities()},
        doc: "Finding severity. Required — the verifiers refuse a rule without one."
      ],
      revision: [type: :string, doc: "The rule revision. Defaults to `\"1\"`."],
      message: [
        type: :string,
        doc:
          "The finding message template. `%{variable}` placeholders are rendered " <>
            "from the match bindings; defaults to the rule name."
      ],
      remediation_ref: [type: :string, doc: "Reference to remediation guidance."],
      controls: [type: {:wrap_list, :string}, default: [], doc: "Control mappings for this rule."],
      evidence: [
        type: {:wrap_list, :string},
        default: [],
        doc: "Evidence requirements for this rule."
      ],
      source: [type: :string, doc: "Provenance citation for this rule."]
    ],
    entities: [
      applicability: [@requires],
      failure_conditions: [@fails],
      outcomes: [@outcome]
    ]
  }

  @combining %Spark.Dsl.Entity{
    name: :combining,
    target: CombiningRef,
    args: [:algorithm],
    describe: "Declares the rule set's combining algorithm.",
    examples: ["combining :deny_overrides"],
    schema: [
      algorithm: [
        type: {:in, Combining.algorithms()},
        required: true,
        doc: "The XACML-derived combining algorithm. Defaults to `:deny_overrides`."
      ]
    ]
  }

  @rules %Spark.Dsl.Section{
    name: :rules,
    top_level?: true,
    describe: "Rules and the combining algorithm, declared at the top level of the module.",
    entities: [@rule, @combining],
    singleton_entity_keys: [:combining]
  }

  use Spark.Dsl.Extension,
    sections: [@fact_schema, @rules],
    transformers: [AshRules.Dsl.Transformers.CompileBundle],
    verifiers: [
      AshRules.Dsl.Verifiers.VerifyFactSchema,
      AshRules.Dsl.Verifiers.VerifyRules
    ]
end
