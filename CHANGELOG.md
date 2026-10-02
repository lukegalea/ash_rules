<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Nothing has been released yet. Everything below is the initial body of work.

### Documentation:

- README: the "how it fits" seam diagram, and screenshots from the reference
  integration (findings with explanations, rule-set layers, the evaluation
  audit trail), captured live from the `ash_enterprise` KYC demo.
- `LICENSES/MIT.txt` added alongside the root `LICENSE`, matching the
  first-party package convention; every documentation asset carries its
  `.license` sidecar.

### Features:

- Standing queries (`AshRules.Standings`, S1-55): membership-change events
  over a watched set expression — `diff/2` yields one event per subject
  whose three-valued verdict changed (`:entered`, `:left`,
  `:became_unknown`, `:resolved_out`, each carrying its exact `from`/`to`),
  `unknown` never folded into `in` or `out`; `query/3` derives the
  expression's content-hashed identity; `dispatch/4` delivers the stream
  through the one-callback `Standings.Dispatcher` behaviour hosts implement
  (BPMN starts/signals and notifications as documented reference consumers);
  `run/5` is the derive-diff-dispatch round trip, silent on empty diffs.
- The standing-query diff property: against partitions the set-equivalence
  properties already trust, the diff is exactly the per-subject partition
  change, and applying the events reconstructs the after partition exactly.
- Set evaluator (`AshRules.Evaluator.Set`, ADR 0048): IR predicates compiled
  into Ash queries over facts, partitioning subjects `in` / `out` / `unknown`
  — membership is three-valued, `unknown` never folds into either side.
  Runs over in-memory fact triples or any fact resource exposing `subject`,
  `predicate`, `value`; the compiled queries re-verify candidates with the
  IR's strict equality, so set matching is exactly rule matching. Exposed as
  `AshRules.membership/4` and `Set.compile/2` + `Set.membership/3`.
- The equivalence property (`AshRules.SetMembershipPropertyTest`): for
  randomly generated predicates and fact sets — empty and single-fact sets
  included — set membership equals the direct evaluator's per-subject
  outcome, on the facts path and on the compiled-query resource path.
- Serializable rule IR (`AshRules.Ir`): rules, fact schemas and bundles as plain
  data with a validated JSON codec and a SHA-256 content hash over canonical
  JSON.
- Outcome lattice (`AshRules.Outcome`): `compliant`, `noncompliant`,
  `not_applicable`, `unknown`, `error` — `unknown` and `error` never collapse to
  `compliant`.
- XACML-derived combining algorithms (`AshRules.Combining`): `deny_overrides`
  (default), `permit_overrides`, `first_applicable`, `only_one_applicable`,
  each covered by full truth tables.
- Spark DSL (`use AshRules`) compiling to the IR, exposed as `__bundle__` and
  `__rules__`, with compile-time verifiers for unknown predicates, type
  mismatches, unbound variables, missing outcomes/severities and missing
  combining metadata.
- `AshRules.Evaluator` behaviour with two adapters: `AshRules.Evaluator.Direct`
  (pure Elixir, deterministic, no dependencies) and `AshRules.Evaluator.Wongi`
  (compiles the IR to Wongi.Engine rules; only compiled when the optional
  dependency is present, `{:error, :wongi_not_available}` otherwise).
