<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# What it refuses

AshRules validates before activation, never at evaluation — the Cedar
pattern. Every refusal names the failing rule (or fact) and the fix. The same
checks run at compile time for DSL-authored rule sets and at admission for
decoded tenant IR; there is no `Code.eval` on any path and no persisted AST
anywhere.

Compile-time refusals surface as compiler diagnostics, which fail any build
running with `--warnings-as-errors` — this repository's compile gate, and the
recommended setting for hosts.

## Rules

* **Unknown predicate** — `rule "kyc.required": predicate :nonsense is not in
  the fact schema. Declare it in fact_schema with `fact :nonsense, :type``
* **Value type mismatch** — `predicate :flag value "yes" does not type-check
  against :boolean. Use a boolean value`
* **Closed vocabulary violation** — `predicate :status value :deleted does not
  type-check against :atom (one_of: [:active, :suspended]). Use one of the
  declared values`
* **Unbound variable** — `variable :account is used before it is bound. Bind
  it with an earlier has(...) clause in when_requires` (`neg` never binds:
  absence cannot bind)
* **Missing severity** — `no severity declared. Add `severity: :low |
  :medium | :high | :critical` to the rule`
* **Missing outcome** — `no outcome declared. Add `outcome :noncompliant,
  gap: "<control reference>"` to the rule body`
* **Missing combining metadata** — `outcome :noncompliant has no gap.
  Combining metadata must be present at every level — add `gap: "<control
  reference>"` to the outcome`
* **Duplicate rule id** — `id is declared more than once. Rule ids must be
  unique — they are the provenance key every finding is filed under`
* **Multiple outcomes** — a rule declares exactly one outcome
* **Unknown rule option** — `unknown rule option(s) [:nonsense]`, listing the
  valid ones
* **A rule that fires cannot assert a good state** — `:compliant` and
  `:not_applicable` outcome declarations are refused

## Fact schemas

* **Duplicate fact** — `fact :flag is declared more than once. Remove the
  duplicate declaration — one fact, one schema entry`
* **`one_of` on a non-atom fact** — `fact with type :boolean declares one_of
  [true]. one_of constrains `:atom` facts — declare the fact as `:atom` or
  drop the one_of`
* **Empty `one_of`** — list the allowed values or drop it
* **Unknown type, missing semantics or cardinality** — validated against the
  supported domains

## Working memory

* **Undeclared predicate** — `fact {:customer, :nonsense, 1}: predicate
  :nonsense is not in the fact schema. Declare it with `fact :nonsense,
  :type` in fact_schema, or drop the fact`
* **Value violates the schema** — type and `one_of` checks, naming the
  offending triple

## Combining

* **Duplicate declaration** — `combining` may be declared at most once
* **Unknown algorithm** — `unknown combining algorithm :bogus. Use one of:
  [:deny_overrides, :permit_overrides, :first_applicable,
  :only_one_applicable]`

## What is deliberately absent

* **No expression language.** Rules are conjunctions of triple probes with
  variables. Arithmetic, string surgery and cross-fact comparisons belong in
  the facts, precomputed by the host — a rules engine with a programming
  language in its conditions is an interpreter nobody can audit.
* **No persistence, no events, no catalogs.** `ash_rules` owns the rule IR and
  evaluation. Versioned catalog resources, waivers, findings storage and the
  projector live in `ash_compliance`; the bundle hash is the seam between
  them.
* **No global "treat missing as false" switch.** Absence semantics are
  declared per fact (`:false`, `:unknown`, `:no_fact`) and surfaced in
  results. A global switch is how missing evidence becomes compliance.
* **No `Code.eval`, no persisted AST.** Tenant-authored rules enter as
  decoded IR and pass the same verifiers as DSL-authored ones.
* **No non-deterministic evaluation.** There is no mode in which the same
  bundle and facts can produce different results. If a host needs ordered
  evaluation it declares `first_applicable`; it never depends on map or
  process ordering.
