<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AshRules

**A judgment is a predicate over any set**
([ADR 0048](https://github.com/lukegalea/ash_enterprise/blob/main/docs/adr/0048-a-judgment-is-a-predicate-over-any-set.md)).
"Does this vendor do roof work?" is a predicate over a subject. Once it is
admitted it is a fact — a `{subject, predicate, value}` triple. A filter, a
search, a segment, a standing query and a compliance rule are all
*expressions over the same vocabulary of predicates*, evaluated over a set:
the vendors in Toronto who do roof work and hold a current certificate is the
conjunction of one crisp predicate and two judged ones, run over every vendor.

**AshRules owns that vocabulary and the machines that evaluate it.** A rule
set is a Spark DSL that compiles to an immutable, content-hashed bundle of
serializable IR — no quoted AST, no `Code.eval`, nothing that can't be
hashed, signed, shipped to a tenant control plane, decoded years later and
evaluated identically. The same declared predicates evaluate per subject
(rules, findings, explanations), over a set (filters, search, segments, bulk
selection) and incrementally (Rete, for standing queries) — and the set
evaluator is *proven equivalent* to the per-subject one by property test.
Missing data is never a pass, and in a set it is never folded into `in` or
`out` either.

---

## The idea in thirty seconds

Declare the predicates once:

```elixir
defmodule MyApp.Compliance.Rules do
  use AshRules

  fact_schema do
    fact :status, :atom, one_of: [:active, :suspended]
    fact :jurisdiction, :atom
    fact :has_valid_kyc, :boolean, missing: :unknown
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium do
    when_requires has(:customer, :status, :active),
                  has(:customer, :jurisdiction, :regulated)
    fails_when neg(:customer, :has_valid_kyc, true)
    outcome :noncompliant, gap: "kyc.valid_required"
  end
end
```

Evaluate them **per subject** — with an outcome and full provenance:

```elixir
{:ok, result} =
  AshRules.evaluate(MyApp.Compliance.Rules, [
    {:customer, :status, :active},
    {:customer, :jurisdiction, :regulated}
  ])

result.overall
#=> :unknown
```

That `:unknown` is the whole philosophy. No `has_valid_kyc` fact was
supplied, and the schema declares it `missing: :unknown` — so the requirement
is **unknown**, not noncompliant and not compliant. Absence of data never
becomes a violation, and never becomes a pass. Every compliance framework's
ugliest failures start with a boolean somewhere deciding that "we don't know"
means "fine".

Evaluate them **over a set** — the same predicates, compiled into Ash queries
over the fact table, partitioning subjects three ways:

```elixir
predicates = [
  has(var(:s), :status, :active),
  neg(var(:s), :has_valid_kyc, true)
]

{:ok, membership} =
  AshRules.membership(MyApp.Compliance.Rules, predicates, fact_resource_or_triples)

membership.in      #=> subjects an admitted fact puts in
membership.out     #=> subjects an admitted fact puts out
membership.unknown #=> subjects no fact decides — never folded either way
```

A saved filter, a segment, a bulk selection: that call. The IR predicates are
the same ones the rule declares; the equivalence property test proves that
for every subject, set membership equals the per-subject outcome — two
evaluators that could disagree would give two answers to one question, which
is worse than one.

## Membership is three-valued

A judged predicate partitions a set three ways, not two
([ADR 0048](https://github.com/lukegalea/ash_enterprise/blob/main/docs/adr/0048-a-judgment-is-a-predicate-over-any-set.md)):

| Partition | Meaning |
|---|---|
| **in** | an admitted fact says the predicate holds |
| **out** | an admitted fact says it does not |
| **unknown** | no admitted fact: never assessed, awaiting review, or absent under `missing: :unknown` |

`unknown` is always surfaced — as a partition you can count and act on
("assess these 40") — and never folded into either side. Negation is over
admitted facts only: "vendors that do *not* do roof work" is the `out`
partition, not everything outside `in`. Absence semantics come from the same
fact schema the rule evaluator honours: an absent probe on a
`missing: :unknown` predicate lands in `unknown`; under `missing: :false` /
`:no_fact` absence resolves as `false` would, exactly as it does per subject.

**Scores order; facts decide.** The set evaluator reads admitted facts only
— never observations, never model output. A filter is a database query:
indexable, composed with policies, the same cost on the thousandth call as
on the first.

## One IR, three evaluators, proven equivalent

| Evaluator | Answers | Used by |
|---|---|---|
| Per-subject (`AshRules.Evaluator.Direct`) | "what is the outcome for this subject, and why" | rules, findings, explanations |
| Set (`AshRules.Evaluator.Set`) | "which subjects are in, out, unknown" | filters, search, segments, bulk selection |
| Incremental (`AshRules.Evaluator.Wongi`) | "whose membership just changed" | standing queries, alerts, process starts |

The set evaluator compiles IR predicates into Ash queries over facts — the
queries narrow with the data layer's own equality (indexable, pushdownable)
and re-verify every candidate with the IR's strict `===`, so `80` does not
match a fact that says `80.0` in a query any more than in a rule. It runs
against in-memory fact triples or against any Ash fact resource exposing
`subject`, `predicate` and `value` — with `opts` forwarded to `Ash.read/2`,
policies apply as for any read. Two evaluators that can disagree would give
two answers to one question: the property test runs randomly generated
predicates and fact sets through both and asserts the partitions are equal,
subject by subject.

## How it fits

AshRules owns the predicate vocabulary and the evaluation. It does not own
storage, events, or the program around them — the packages downstream of it
do:

```
        ┌─────────────────────────────────────────────────────┐
        │  use AshRules                    (compile time)     │
        │  rule set DSL ──verify──► immutable IR bundle       │
        │                            SHA-256 content hash     │
        └────────────────────────────┬────────────────────────┘
                                     │  JSON in both directions
                                     ▼
        ┌─────────────────────────────────────────────────────┐
        │  runtime, one vocabulary, three evaluators          │
        │                                                     │
        │  Evaluator.Direct  ← per subject (default)          │
        │  Evaluator.Set     ← over a set, Ash queries        │
        │  Evaluator.Wongi   ← incrementally (optional Rete)  │
        │    (equivalence pinned by property test)            │
        │                                                     │
        │  ⇒ Result: per-rule outcomes, provenance,           │
        │    derived + missing facts, bundle hash             │
        │  ⇒ Membership: in / out / unknown, per subject      │
        └────────────────────────────┬────────────────────────┘
                                     │
        ┌────────────────────────────▼────────────────────────┐
        │  hosts: store the bundle as an approved artifact,   │
        │  project results into findings, run filters and     │
        │  segments over their fact tables, pin every         │
        │  decision to the hash that produced it              │
        └─────────────────────────────────────────────────────┘
```

The seam is deliberate: everything above the line is predicates-as-data,
everything below decides what to do with the answers. Swap the evaluator
without touching a rule; version a rule set without touching an evaluator.

## What ships

* **Serializable rule IR** (`AshRules.Ir`) — rules, fact schemas, bundles as
  plain data. `AshRules.Ir.decode/1` validates on admission with the *same
  verifiers the DSL applies at compile time*: unknown predicates, type
  mismatches, unbound variables, missing outcomes — a refusal is a refusal no
  matter which door the rules came through. Every bundle carries a SHA-256
  content hash over canonical JSON; results pin the hash, so a finding always
  names the exact rules that produced it. The canonical form of a saved
  filter or segment is this IR.
* **The set evaluator** (`AshRules.Evaluator.Set`) — IR predicates compiled
  into Ash queries over facts, returning the `in` / `out` / `unknown`
  partition per ADR 0048. Refusals are compile-time and name the fix; v0 set
  expressions are conjunctions over one subject (one designated variable or
  one ground subject, plus context conditions about other fixed subjects).
* **An outcome lattice** (`AshRules.Outcome`) — `compliant`, `noncompliant`,
  `not_applicable`, `unknown`, `error`. `unknown` and `error` never collapse to
  `compliant`; the property suite asserts it, not just this page.
* **XACML-derived combining** (`AshRules.Combining`) — `deny_overrides`
  (default), `permit_overrides`, `first_applicable`, `only_one_applicable`,
  each covered by full truth tables over the lattice.
* **Compile-time verification** — the Cedar pattern: validate before activate,
  never at evaluation. Tenant-authored rules enter as decoded IR and pass the
  identical checks.
* **One evaluator behaviour, two engines** — `AshRules.Evaluator.Direct`
  (pure Elixir, zero dependencies, deterministic by construction) and
  `AshRules.Evaluator.Wongi` (compiles the IR to Wongi.Engine rules with full
  truth maintenance). Both produce identical results on the same inputs; the
  contract is enforced by the test suite, not by optimism.

## What evaluation produces

An `AshRules.Result` per bundle evaluation:

* one **requirement** per rule: outcome, severity, gap (the combining
  metadata), rendered message, variable bindings;
* **provenance**: the working-memory facts each fired requirement consumed,
  and the ground probes checked against absence — the auditor's chain from
  rule revision to control mapping to consumed facts;
* **derived facts** — findings materialized as triples, deterministic and
  index-stable;
* **missing facts** — the absences the schema says must be surfaced;
* the **overall outcome** under the bundle's combining algorithm, plus the
  bundle hash, both revisions, and the evaluation seed.

A set evaluation produces an `AshRules.Evaluator.Set.Membership`: the sorted
subjects per partition, disjoint and covering the universe of subjects
present in the fact source (subjects with no facts at all cannot be
enumerated from a fact table — joining the host's subject resource is the
host's move, and it is where "never assessed" lives).

## Compliance is the first consumer

The reference integration (customer KYC compliance, in `ash_enterprise`) runs
these rules over a real event log and projects the results into findings. The
screenshots are that integration, unmodified:

![A findings table where missing evidence reads "cannot evaluate … missing customer/sanctions_cleared" — unknown, never compliant](documentation/assets/findings-explanations.png)

Every row's explanation is the rule's own message or the missing-fact summary,
projected at evaluation time. The outcome lattice is visible in the status
column: *unknown* sits between compliant and noncompliant and never collapses
into either.

![Rule set revisions across the four layers, each with its lifecycle status and combining algorithm](documentation/assets/rule-set-layers.png)

A rule set is a revision with a lifecycle (draft → validated → approved →
active) and a layer that decides what may waive or replace it. The audit row
below the two active baselines is revision 2 of the baseline, seeded as a
draft: activating it is a reviewed act, not a deploy.

![The evaluation log: one append-only row per decision, each pinning the bundle hash and the facts that were missing](documentation/assets/evaluation-provenance.png)

Each evaluation records the bundle hash that produced it, the fact snapshot
hash, and what was missing. Replay the same events and the evaluations are
byte-identical — that is the acceptance bar, asserted by the test suite.

## Installation

Not yet on Hex. As a git dependency:

```elixir
defp deps do
  [
    {:ash_rules, github: "lukegalea/ash_rules"}
  ]
end
```

Wongi.Engine is an **optional** dependency. Add `{:wongi_engine, "~> 0.9"}` to
your own deps to get the Rete adapter; without it, everything else works and
`AshRules.Evaluator.Wongi` is a stub returning
`{:error, :wongi_not_available}`. `AshRules.Evaluator.Direct` — the default —
needs nothing beyond `ash`, `spark` and `jason`.

`mix igniter.install ash_rules` handles the formatter wiring.

## Documentation

- [Rules and fact schemas](documentation/topics/rules-and-fact-schemas.md) —
  the DSL, absence semantics, variables, metadata.
- [Evaluators](documentation/topics/evaluators.md) — the behaviour, the two
  engines, the set evaluator, parity, equivalence and determinism contracts.
- [What it refuses](documentation/topics/what-it-refuses.md) — the compile-time
  and admission-time refusals, verbatim.

## Status

0.1.0. The IR, DSL, verifiers, all three evaluators and the combining
algorithms are exercised by golden tests, full combining truth tables,
determinism runs (n=50), StreamData properties over random fact sets, a
direct-vs-Wongi parity corpus, and the set-equivalence property: for
randomly generated predicates and fact sets — empty and single-fact sets
included — set membership equals the direct evaluator's per-subject outcome,
on the facts path and on the compiled-query resource path. The reference
integration (customer KYC compliance) lives in `ash_enterprise`;
`ash_compliance` builds its control plane and projector on this package's IR
and evaluator behaviour.

## Contributing

Issues and PRs at [github.com/lukegalea/ash_rules](https://github.com/lukegalea/ash_rules).
`mix compile --warnings-as-errors`, `mix test`, `mix format --check-formatted`
and `mix credo --strict` must pass; CI runs all four.

## License

MIT.
