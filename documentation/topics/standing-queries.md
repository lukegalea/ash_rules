<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Standing queries

A standing query is a set expression watched over time: when the facts
change, its membership is re-derived and every subject whose verdict changed
becomes an event. Events are how a standing set expression reaches out —
starting or signalling BPMN processes, notifying people, opening assess
tasks ([ADR 0048](https://github.com/lukegalea/ash_enterprise/blob/main/docs/adr/0048-a-judgment-is-a-predicate-over-any-set.md);
[SYNTHESIS §2.2](https://github.com/lukegalea/system-one-program/blob/main/SYNTHESIS.md)
laws 13–16; RFC S1-24 Q22).

The laws the events inherit:

* **One vocabulary** (law 13): a standing query is a declared set expression
  over the fact schema, content-hashed and activated like any other bundle.
  Events name that identity — never a private restatement of the predicate.
* **Membership is three-valued** (law 14): the events are a function of
  three-valued partitions, and `unknown` is never folded into `in` or `out`
  — see [the transition table](#the-transition-table).
* **Queries read; instruments backfill** (law 15): the events derive from
  re-derived partitions; the unknowns they surface are filled by
  materialisation or assessment, and the next derivation reads the result.
* **Scores order; facts decide** (law 16): events derive from admitted facts
  only — never observations, never scores. Whatever a dispatcher does with
  them, it is acting on facts.

## The pieces

```elixir
# The identity + compiled plan. hash is derived from the predicates' canonical
# JSON, or overridden with opts[:hash] to carry the activated bundle's own
# AshRules.Ir.Bundle.content_hash/1.
{:ok, query} =
  AshRules.Standings.query(schema_or_bundle, predicates,
    name: "vendor roof work",
    hash: bundle.content_hash
  )

# Derive membership through the set evaluator (triples, Facts, or a fact
# resource — the same sources as AshRules.Evaluator.Set).
{:ok, before} = AshRules.Standings.evaluate(query, facts_before)
{:ok, after_partition} = AshRules.Standings.evaluate(query, facts_after)

# The core: a pure diff of two partitions.
events = AshRules.Standings.diff(before, after_partition)

# The host seam: deliver the stream to the host's dispatcher.
:ok = AshRules.Standings.dispatch(query, events, MyDispatcher, tenant: tenant)

# Or the whole round trip: derive, diff, dispatch (an empty diff calls no
# callback — a sweep that found no change is silent).
{:ok, events} =
  AshRules.Standings.run(query, facts_before, facts_after, MyDispatcher, tenant: tenant)
```

`AshRules.Standings.Dispatcher` is the behaviour hosts implement — one
callback, `handle_events(query, events, opts)`, receiving the whole stream
for one diff, sorted by subject, with the standing query's identity. The
library owns detection and the contract; the host owns delivery. There is no
dependency on any BPMN or notification library.

## The transition table

Membership is three-valued, and so is the diff. `unknown` is never folded
into either side:

| from \ to | `in` | `out` | `unknown` |
|---|---|---|---|
| **`in`** | — | `:left` | `:became_unknown` |
| **`out`** | `:entered` | — | `:became_unknown` |
| **`unknown`** | `:entered` | `:resolved_out` | — |

Every event carries `from` and `to`, so the same kind may arrive from
different previous verdicts and the consumer can always tell:

* **`:entered`** — the subject now satisfies the standing query (`out → in`,
  or `unknown → in` once an admitted fact decides it positively).
* **`:left`** — the subject was in and an admitted fact now says it is not
  (`in → out` **only**). `in → unknown` is *not* a `:left`: an undecidable
  membership is not a negative one, it is `:became_unknown` with
  `from: :in`.
* **`:became_unknown`** — the set can no longer decide (`in → unknown` or
  `out → unknown`; `from` distinguishes). The in-set lifecycle action is
  pause-and-assess, not revoke: revoking implies the subject was out, and
  an unknown never was.
* **`:resolved_out`** — an undecidable subject resolved definitively
  negative (`unknown → out`). None of the three standing-query kinds can
  name this without lying: it is not a `:left` (the subject was never in —
  law 14), and silence would fold `unknown` into `out` (a real verdict
  change, dropped). Consumers act on the in-set lifecycle, so this kind
  needs no in-set action — it retires an unknown.

A subject present in one partition and absent from the other is read as
`:unknown` on the missing side — no deciding fact is exactly the unknown
partition's meaning — so a fact source that shrinks degrades to
`:became_unknown`, never to `:left`.

The property test (`AshRules.StandingsPropertyTest`) pins the table end to
end: against partitions the S1-54 equivalence properties already trust, the
diff is exactly the per-subject change, and applying the events to the
before partition reconstructs the after partition exactly.

## Reference consumer: BPMN (signals and starts)

Modelled on the `ash_enterprise` wiring (`ash_bpmn`'s Subscription →
Dispatch → instance start): the host registers one subscription per
activated standing query, and its dispatcher turns each event into one
**dispatch row persisted in the same transaction as the message it
delivers** — the row is the answer to "why did this process start?".

* `:entered` — deliver a message that starts (or advances) the process.
  Name messages from the standing query's identity so a subscription can
  catch them declaratively: `ash_rules/<query.hash>/entered`.
* `:became_unknown` with `from: :in` — the running instance's premise
  lapsed: signal the instance (pause at a gateway, raise a human task).
  With `from: :out`, there is no running instance — record the row, start
  nothing.
* `:left` — signal the instance to close.
* `:resolved_out` — no instance is running for a subject that was never in;
  record the row, retire the unknown.

The exemplar in `AshRules.StandingsTest` (`BpmnStyleDispatcher`) pins this
shape in miniature. The host's real dispatcher writes its dispatch rows with
its repo, inside the transaction that starts the instance or delivers the
signal.

## Reference consumer: notifications

* `:entered` — notify ("this vendor now qualifies").
* `:left` — notify the revocation.
* `:became_unknown` — open an **assess task** instead of notifying a
  verdict: an undecidable membership is work, not a result, and it is never
  rendered as either `in` or `out`.
* `:resolved_out` — nothing to notify.

The exemplar (`NotificationStyleDispatcher` in `AshRules.StandingsTest`)
pins the mapping. A host that distinguishes admission grades states its
minimum grade when it acts (RFC S1-24 Q19) — the events themselves carry
subjects and transitions, and the grade gate stays with the consumer, per
"scores order; facts decide".

## Where Rete fits

Membership is derived, never stored (S1-24 §7.4), so the incremental path is
re-derive and diff: `run/5` over the before and after fact sources. A Rete
engine (the optional `AshRules.Evaluator.Wongi`) narrows *who* to re-evaluate
as facts arrive — but token-level productions cannot see the unknown
partition, so the diff over re-derived partitions is what makes the events
three-valued. Rete remains an optimization for choosing what to re-derive,
not the event contract.
