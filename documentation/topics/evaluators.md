<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Evaluators

## The behaviour

```elixir
@callback evaluate(AshRules.Ir.Bundle.t(), AshRules.Facts.t() | [AshRules.Facts.triple()], keyword()) ::
            {:ok, AshRules.Result.t()} | {:error, term()}
```

Facts are `{subject, predicate, value}` triples validated against the bundle's
fact schema before anything evaluates: a fact whose predicate is undeclared or
whose value violates the schema is an error, never a silent mismatch. `opts`
may carry `:evaluator` (through `AshRules.evaluate/3`) and a `:seed`, which is
recorded on the result as an audit marker.

## Direct — the default

`AshRules.Evaluator.Direct` matches the IR predicates in pure Elixir with
variable binding and three-valued absence resolution. No dependencies, no
process, no state: the same bundle and facts produce a byte-identical result
every time, because determinism is structural — rules in id order, candidates
in sorted order, findings indexed over a sorted binding list — not because
nothing went wrong yet.

## Wongi — the optional Rete engine

`AshRules.Evaluator.Wongi` compiles each IR rule to two Wongi.Engine rules:
one over the applicability matchers (marking the rule applicable), one over
applicability plus failure conditions (generating the finding). The split is
what lets it agree with Direct on `:compliant` versus `:not_applicable`.
Provenance comes from `Wongi.Engine.tokens/2` on the production refs,
translated back to domain rule ids — engine refs never escape the adapter.

Missing-data semantics are resolved *before* compilation through the same
`AshRules.Facts` helpers Direct uses, so the network sees exactly what Direct
sees. Rules whose evaluation would reach an absent `missing: :unknown` probe
are withheld and reported `:unknown` — with the probe that killed them,
honouring short-circuiting, via a shared reachability check the two evaluators
cannot disagree on.

Generated facts are retracted automatically when their support disappears:
retract a premise, assert the contradicting fact, and the finding goes with
it. `AshRules.Evaluator.Wongi.engine/2` hands you the live engine (keyed by
domain rule id) for interactive truth maintenance.

The module only compiles when `wongi_engine` is loadable. Hosts without it get
a stub returning `{:error, :wongi_not_available}` — never a missing-module
crash.

## Set — membership over facts (ADR 0048)

`AshRules.Evaluator.Set` answers a different question over the same IR
predicates: not "what is the outcome for this subject" but "which subjects are
in, out, unknown". A filter, a segment, a saved search or a bulk selection is
a conjunction of declared predicates evaluated over a set, and membership is
three-valued: `in` when an admitted fact says the predicate holds, `out` when
one says it does not, `unknown` when no fact decides — surfaced, countable,
and never folded into either side.

```elixir
{:ok, plan} =
  AshRules.Evaluator.Set.compile(schema, [
    has(var(:s), :owner, :customer),
    neg(var(:s), :has_valid_kyc, true)
  ])

{:ok, membership} = AshRules.Evaluator.Set.membership(plan, facts_or_resource)
membership.in      #=> subjects an admitted fact puts in
membership.out     #=> subjects an admitted fact puts out
membership.unknown #=> subjects no fact decides
```

`membership/3` takes raw fact triples, a prepared `AshRules.Facts` struct, or
a fact resource module. On the resource path the predicates compile into Ash
queries — the probed-fact rows and the any-value rows per probe — run through
`Ash.read/2` with `opts` forwarded, so policies apply as for any read. The
resource contract is three attributes: `subject`, `predicate` (the string
spelling of the IR name) and `value`.

Two invariants make it exact rather than approximate:

* **Strict equality.** The compiled query narrows with the data layer's own
  equality (indexable, pushdownable — numeric coercion can only widen it);
  every candidate is then re-verified with `AshRules.Ir.values_equal?/2`, so
  a probe that says `80` never matches a fact that says `80.0` in a set any
  more than in a rule.
* **Absence semantics.** Absence resolves through the fact schema exactly as
  `AshRules.Facts.absence/2` resolves it per subject: `missing: :unknown`
  puts the subject in `unknown`; `missing: :false`/`:no_fact` resolves as
  `false` would — `has(…, false)` synthesizes a match, and `neg(…, false)`
  fails against the synthesized triple.

Conjunctions scan probes in clause order and the first deciding probe wins,
which is Direct's short-circuit semantics per subject. The set expression's
v0 shape: one subject — all probes about a designated variable (`var(:s)`),
or all probes about one ground subject. Probes about *other* ground subjects
are context conditions (the same answer for every member). Refused at compile
time: two distinct variables, variables in a value position, and ground-only
conjunctions probing more than one subject. The universe is the subjects
present in the fact source; subjects with no facts at all cannot be enumerated
from a fact table, so joining the host's subject resource — where "never
assessed" lives — is the host's move (S1-24 §7.4: the set evaluator reads the
fact table only).

**The equivalence property** (`AshRules.SetMembershipPropertyTest`): for
randomly generated predicates and fact sets, for every subject, set membership
equals the direct evaluator's per-subject outcome — all probes hold → in, a
probe definitively fails → out, a probe undecidable → unknown — on the facts
path and on the compiled-query resource path. Two evaluators that can
disagree would give two answers to one question, which is worse than one.

## The parity contract

Both evaluators must produce identical results on the same bundle and facts:
per-rule outcomes, bindings, messages, missing facts, derived facts and the
overall outcome, plus consumed-fact provenance for fired requirements. The
test suite runs every golden case and a property-generated corpus through
both. Unfired rules may differ in *probe bookkeeping* (`probed_facts` — Direct
records the absence checks a network has no reason to record); decisions never
differ.

## Results

`AshRules.Result` carries `requirements` (one per rule), `derived_facts`
(findings as `{rule_id, :finding, n}` triples), `missing_facts`, the
`overall` outcome, the `bundle_hash` and revisions the evaluation pinned, the
combining algorithm, the evaluator module and the seed. `AshRules.Result.findings/1`
returns the fired requirements — everything an auditor or a projector needs.
