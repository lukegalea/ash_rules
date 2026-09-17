<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Rules and fact schemas

## The shape of a rule set

```elixir
defmodule MyApp.Compliance.Rules do
  use AshRules

  combining :deny_overrides

  fact_schema do
    fact :status, :atom, one_of: [:active, :suspended]
    fact :jurisdiction, :atom
    fact :has_valid_kyc, :boolean, missing: :unknown
    fact :reviewed, :boolean, missing: :no_fact
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium,
    message: "customer %{customer} needs KYC",
    controls: ["KYC-01"] do
    when_requires has(:customer, :status, :active),
                  has(:customer, :jurisdiction, :regulated)
    fails_when neg(:customer, :has_valid_kyc, true)
    outcome :noncompliant, gap: "kyc.valid_required"
  end
end
```

Three things are declared: the **fact schema** (what may be probed), the
**rules** (what must hold when), and the **combining algorithm** (how
per-rule outcomes become one overall outcome).

## Fact schemas

A `fact` entry declares a predicate's value type, its closed vocabulary (for
`:atom` facts), and — most importantly — what **absence means**:

| `missing:`   | absence is …                                                              | reported in `missing_facts`? |
|--------------|---------------------------------------------------------------------------|------------------------------|
| `:false`     | the value `false`; probes evaluate against it                              | yes — "no data" became "false", an auditor wants to know |
| `:unknown`   | undecidable; every rule probing the fact evaluates to `:unknown`           | yes |
| `:no_fact`   | an expected, meaningful state ("not reviewed yet"); probes behave as false | no |

Types: `:atom`, `:boolean`, `:string`, `:integer`, `:float`, `:number`,
`:date`, `:utc_datetime`, `:any`. Rule predicates are type-checked against the
schema at compile time; working-memory facts are checked at evaluation time —
both refuse with a message naming the fact and the fix.

## Rule bodies

* `when_requires has(...), neg(...)` — applicability. All must hold, or the
  rule is `:not_applicable`.
* `fails_when has(...), neg(...)` — failure conditions. All must hold for a
  rule that applies to fire; otherwise it is `:compliant`.
* `outcome :noncompliant, gap: "control.reference"` — what firing asserts, and
  the combining metadata the finding is filed under. `:noncompliant` without a
  gap is refused: an unfiled finding cannot be waived, tracked or aggregated.

An empty `when_requires` means the rule always applies.

## Variables

`var(:name)` in a `has` subject or value position binds on first match and
unifies thereafter — one finding per complete binding:

```elixir
rule "suspended customer with non-zero balance is a finding",
  id: "acct.balance_frozen",
  severity: :low,
  message: "account %{account} holds a non-zero balance while suspended" do
  when_requires has(:customer, :status, :suspended),
                has(var(:account), :owner, :customer)
  fails_when neg(var(:account), :balance, 0)
  outcome :noncompliant, gap: "acct.balance"
end
```

`neg` clauses never bind — every variable in one must already be bound by an
earlier `has`, or the verifiers refuse the rule. `%{placeholders}` in the
message render from the match bindings.

## Rule metadata

`severity` (`:low | :medium | :high | :critical`) and an `outcome` are
mandatory. `revision`, `message`, `remediation_ref`, `controls`, `evidence`
and `source` carry the audit context. Rule `id`s are unique and stable — they
are the provenance key every finding is filed under.

## Combining

`combining :deny_overrides` (the default) aggregates per-rule outcomes into
the overall outcome. See `AshRules.Combining` for the four algorithms and
their exact semantics.

## The compiled bundle

`MyApp.Compliance.Rules.__bundle__()` returns the compiled
`AshRules.Ir.Bundle`: rules and schema sorted, revisions, the combining
algorithm, and the SHA-256 content hash over its canonical JSON. The hash is
stable across processes and declaration order, and changes when any rule or
schema entry changes — it is the bundle's identity, and results pin it.
`AshRules.Ir.encode/1` and `AshRules.Ir.decode/1` move bundles across the wire
with full validation on admission.
