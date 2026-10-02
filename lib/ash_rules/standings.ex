# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Standings do
  @moduledoc """
  Standing queries: a declared set expression watched over time, its
  membership changes dispatched as events to hosts (BPMN starts and signals,
  notifications, assess queues).

  A standing query is a saved set expression — content-hashed, versioned and
  activated like any other bundle (ADR 0048; SYNTHESIS §2.2 law 13) — plus a
  host-side dispatcher. When the facts change, the query's membership is
  re-derived and diffed against the previous partition; every subject whose
  verdict changed becomes an event naming the set expression and the subject
  (RFC S1-24 Q22: an ordinary platform event, never a judgment record).
  Events derive from partitions of admitted facts only — scores order, facts
  decide (law 16); membership is derived, never stored (S1-24 §7.4).

  ## The transition table

  Membership is three-valued, and so is the diff. `unknown` is never folded
  into either side — not into `in` (a subject that was never in cannot
  `left`), and not into `out` (an undecidable verdict is not a negative one,
  so `unknown → out` is a real change and is never silence):

  | from \\ to | `in` | `out` | `unknown` |
  |---|---|---|---|
  | **`in`** | — | `:left` | `:became_unknown` |
  | **`out`** | `:entered` | — | `:became_unknown` |
  | **`unknown`** | `:entered` | `:resolved_out` | — |

  Every event carries `from` and `to`, so `out → unknown` and `in → unknown`
  are the same *kind* with different payloads, and a consumer never has to
  guess. `:resolved_out` exists because none of the three standing-query
  kinds can name `unknown → out` without lying: it is not a `:left` (the
  subject was never in — law 14) and it is not silence (the set's verdict
  changed from undecidable to definitively negative). Consumers act on the
  in-set lifecycle: `:entered` starts and notifies, `:left` closes and
  revokes, `:became_unknown` pauses for assessment; `:resolved_out` needs no
  action on the in-set — it retires an unknown.

  A subject present in one partition and absent from the other is read as
  `:unknown` on the missing side — no deciding fact is exactly what the
  unknown partition means — so a fact source that shrinks degrades to
  `:became_unknown` and never to `:left`.

  ## The incremental path

  Membership is derived, never stored, so the honest incremental path is
  re-derive and diff: `run/5` evaluates the plan over the before and after
  fact sources through the set evaluator and dispatches the diff. A Rete
  engine narrows *who* to re-evaluate as facts arrive (ADR 0048's
  "whose membership just changed"), but token-level productions cannot see
  the unknown partition — the diff over re-derived partitions is what makes
  the events three-valued, so it is the contract, and Rete remains an
  optimization for choosing what to re-derive.
  """

  alias AshRules.Evaluator.Set
  alias AshRules.Evaluator.Set.Membership
  alias AshRules.Ir.Bundle
  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.Predicate

  defmodule Event do
    @moduledoc """
    One subject's membership change between two partitions of a standing
    query.

    `kind` is the standing-query event (`:entered`, `:left`,
    `:became_unknown`, `:resolved_out`); `from` and `to` carry the exact
    three-valued transition, so the same kind may arrive from different
    previous verdicts and a consumer can always tell.
    """

    defstruct [:kind, :subject, :from, :to]

    @type verdict() :: :in | :out | :unknown

    @type kind() :: :entered | :left | :became_unknown | :resolved_out

    @type t() :: %__MODULE__{
            kind: kind(),
            subject: term(),
            from: verdict(),
            to: verdict()
          }
  end

  defmodule Query do
    @moduledoc """
    A standing query: the set expression's identity plus its compiled plan.

    `hash` is the expression's content hash — the identity events name (law
    13: saved set expressions are content-hashed). It is derived from the
    canonical JSON of the IR predicates, or taken from `opts[:hash]` when the
    host activated a saved bundle and wants the event stream to carry the
    bundle's own `AshRules.Ir.Bundle.content_hash/1`. `name` is the host's
    advisory label; `plan` is the compiled set expression, available to
    dispatchers that want to explain *why* a subject changed.
    """

    defstruct [:hash, :name, :plan]

    @type t() :: %__MODULE__{
            hash: String.t(),
            name: String.t() | nil,
            plan: AshRules.Evaluator.Set.t()
          }
  end

  defmodule Dispatcher do
    @moduledoc """
    The host-facing dispatch behaviour for standing-query events.

    One callback, receiving the whole event stream for one diff with the
    standing query's identity. Implement it to deliver the events wherever
    the host wants them — BPMN starts and signals, notifications, assess
    queues. Events arrive sorted by subject, one per changed subject, and
    are derived from admitted facts only: whatever the callback does with
    them, it is acting on facts, never on scores (law 16).

    The reference consumer patterns are documented in
    [Standing queries](documentation/topics/standing-queries.md): a
    BPMN-facing dispatcher persists one dispatch row per event in the same
    transaction as the instance start or signal it causes (the row answers
    "why did this process start?"), and a notifications-facing dispatcher
    maps `:entered`/`:left` to notifications and `:became_unknown` to an
    assess task.
    """

    @callback handle_events(Query.t(), [Event.t()], keyword()) :: :ok
  end

  @typedoc "Anything the set evaluator reads facts from."
  @type source() :: Set.source()

  @doc """
  Diffs two partitions of the same standing query into per-subject events.

  One event per subject whose verdict changed, sorted by subject; subjects
  whose verdict did not change produce nothing. A subject missing from one
  partition is read as `:unknown` there (no deciding fact), so a fact source
  that shrank degrades to `:became_unknown`, never to `:left`.
  """
  @spec diff(Membership.t(), Membership.t()) :: [Event.t()]
  def diff(%Membership{} = before, %Membership{} = after_partition) do
    subjects =
      before
      |> subjects()
      |> MapSet.union(subjects(after_partition))
      |> MapSet.to_list()
      |> Enum.sort()

    for subject <- subjects,
        from = verdict(before, subject),
        to = verdict(after_partition, subject),
        from != to,
        kind = kind(from, to) do
      %Event{kind: kind, subject: subject, from: from, to: to}
    end
  end

  defp subjects(%Membership{in: in_subjects, out: out_subjects, unknown: unknown_subjects}) do
    MapSet.new(in_subjects ++ out_subjects ++ unknown_subjects)
  end

  # A subject absent from a partition has no deciding fact there — the
  # unknown partition's exact meaning (law 14), never folded to out.
  defp verdict(%Membership{} = membership, subject) do
    cond do
      subject in membership.in -> :in
      subject in membership.out -> :out
      true -> :unknown
    end
  end

  defp kind(:in, :out), do: :left
  defp kind(:in, :unknown), do: :became_unknown
  defp kind(:out, :in), do: :entered
  defp kind(:out, :unknown), do: :became_unknown
  defp kind(:unknown, :in), do: :entered
  defp kind(:unknown, :out), do: :resolved_out

  @doc """
  Builds a standing query from a set expression: the compiled plan plus the
  identity its events will carry.

  `opts[:name]` is an advisory label; `opts[:hash]` overrides the derived
  expression hash — pass `bundle.content_hash` when the host activated a
  saved bundle and wants events to name that artifact. Compilation refusals
  are the set evaluator's, returned unchanged.
  """
  @spec query(FactSchema.t() | Bundle.t(), [Predicate.t()], keyword()) ::
          {:ok, Query.t()} | {:error, String.t()}
  def query(schema_or_bundle, predicates, opts \\ []) do
    with {:ok, plan} <- Set.compile(schema_or_bundle, predicates) do
      {:ok,
       %Query{
         hash: opts[:hash] || expression_hash(predicates),
         name: opts[:name],
         plan: plan
       }}
    end
  end

  @doc """
  The standing query's content hash over the canonical JSON of its IR
  predicates — the same SHA-256-over-Jason family as the bundle content
  hash, so the identity is stable across processes and evaluations.
  """
  @spec expression_hash([Predicate.t()]) :: String.t()
  def expression_hash(predicates) do
    %{"predicates" => Enum.map(predicates, &Predicate.to_json/1)}
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Derives the standing query's membership over a fact source, through the
  set evaluator (triples, a prepared `AshRules.Facts` struct, or a fact
  resource — `opts` forwarded).
  """
  @spec evaluate(Query.t(), source(), keyword()) :: {:ok, Membership.t()} | {:error, term()}
  def evaluate(%Query{plan: plan}, facts, opts \\ []) do
    Set.membership(plan, facts, opts)
  end

  @doc """
  Delivers an event stream to a dispatcher — the host seam.

  `dispatcher` must implement `AshRules.Standings.Dispatcher`
  (`handle_events/3`); anything else is refused, naming the fix. `opts` are
  forwarded to the callback (tenant, actor hints — the library stays out of
  what they mean).
  """
  @spec dispatch(Query.t(), [Event.t()], module(), keyword()) :: :ok | {:error, term()}
  def dispatch(%Query{} = query, events, dispatcher, opts \\ []) do
    if dispatcher?(dispatcher) do
      dispatcher.handle_events(query, events, opts)
    else
      {:error,
       "#{inspect(dispatcher)} does not implement AshRules.Standings.Dispatcher — " <>
         "define handle_events/3"}
    end
  end

  defp dispatcher?(dispatcher) do
    Code.ensure_loaded?(dispatcher) and
      function_exported?(dispatcher, :handle_events, 3)
  end

  @doc """
  The standing-query round trip: derive the before and after partitions from
  two fact sources, diff, and dispatch the events.

  An empty diff is not dispatched — a sweep that found no change calls no
  callback. Returns the events either way.
  """
  @spec run(Query.t(), source(), source(), module(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def run(%Query{} = query, facts_before, facts_after, dispatcher, opts \\ []) do
    with {:ok, before} <- evaluate(query, facts_before, opts),
         {:ok, after_partition} <- evaluate(query, facts_after, opts),
         events = diff(before, after_partition),
         :ok <- dispatch_events(query, events, dispatcher, opts) do
      {:ok, events}
    end
  end

  defp dispatch_events(_query, [], _dispatcher, _opts), do: :ok

  defp dispatch_events(query, events, dispatcher, opts),
    do: dispatch(query, events, dispatcher, opts)
end
