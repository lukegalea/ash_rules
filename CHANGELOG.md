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

### Features:

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
