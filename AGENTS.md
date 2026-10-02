<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_rules`, a pure rule-engine Spark DSL for Ash.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of
the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>.
That file is the root policy for every agent session here. This file adds the
rules of this repository only. It does not replace or weaken the root policy.
If a rule here contradicts a security rule there, stop and ask a human. The
link opens only for people with access to the ai-sdlc repository. If you cannot
open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- Rules are data. A rule set compiles to an immutable, content-hashed bundle
  of serializable IR. There is no quoted AST and no `Code.eval`.
- Missing data is never a pass. An `unknown` outcome never becomes `compliant`
  or `noncompliant`.
- The evaluator is pure. `AshRules.Evaluator.Direct` is the default: pure
  Elixir, zero dependencies, deterministic. `AshRules.Evaluator.Wongi` is an
  optional adapter with the same behavior and the same results.
- `AshRules.Ir.decode/1` applies the same verifiers that the DSL applies at
  compile time. A rule that the DSL refuses is also refused as IR.
- AshRules owns the rule language and the evaluation only. Storage, events,
  and the compliance program belong to the packages downstream of it.

## Before you finish

CI runs `mix compile --warnings-as-errors`, `mix test`,
`mix format --check-formatted`, and `mix credo --strict`. Run all four before
you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the
task adds its own section at the end of this file, between its
`usage-rules-start` and `usage-rules-end` markers. Do not edit text inside
those markers. Keep the rules of this repository above them.
