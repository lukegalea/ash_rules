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
