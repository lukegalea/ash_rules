# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.StandingsPropertyTest do
  @moduledoc """
  The standing-query diff property: **the diff is exactly the per-subject
  partition change.**

  For randomly generated set expressions and randomly generated fact-set
  pairs (before/after — empty sets and shrunken universes in range), the
  partitions come from the set evaluator whose equivalence to the
  per-subject evaluator is already proven (`AshRules.SetMembershipPropertyTest`).
  Against those trusted partitions the property asserts:

    * the diff yields one event per subject whose verdict changed — kind,
      `from` and `to` per the transition table — and nothing else;
    * events are sorted by subject, unique by subject;
    * applying the events to the before partition reconstructs the after
      partition exactly (diff ∘ apply is the identity on membership);
    * `Standings.run/4` delivers exactly these events through the dispatch
      behaviour, and an empty diff dispatches nothing.

  Seeds: StreamData drives properties from the ExUnit seed, so a failure
  reproduces with `mix test --seed <n>`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshRules.Evaluator.Set.Membership
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var
  alias AshRules.Standings
  alias AshRules.Standings.Event
  alias AshRules.TestSupport.RuleSets

  @moduletag :property

  @schema RuleSets.Property.__bundle__().fact_schema

  @names_values %{
    p_a: [:x, :y, :z],
    p_b: [true, false],
    p_c: [0, 1],
    p_d: [true, false],
    p_n: [0, 1, 0.0, 1.0],
    owner: [:customer, :other]
  }

  @subjects [:s1, :s2, :s3, :s4]
  @context_subjects [:customer, :vendor]

  @candidate_facts Enum.flat_map(@subjects, fn subject ->
                     Enum.flat_map(@names_values, fn {name, values} ->
                       Enum.map(values, &{subject, name, &1})
                     end)
                   end)

  defmodule SelfSendingDispatcher do
    @moduledoc "Delivers the stream to the test process — no shared state."
    @behaviour Standings.Dispatcher

    @impl true
    def handle_events(query, events, opts) do
      send(self(), {:standings_events, query, events, opts})
      :ok
    end
  end

  property "the diff is exactly the per-subject partition change" do
    check all(
            predicates <- conjunction_gen(),
            facts_before <- subset_of(@candidate_facts),
            facts_after <- subset_of(@candidate_facts)
          ) do
      {:ok, query} = Standings.query(@schema, predicates)
      assert {:ok, before} = Standings.evaluate(query, facts_before, [])
      assert {:ok, after_partition} = Standings.evaluate(query, facts_after, [])

      events = Standings.diff(before, after_partition)

      # shape: one event per changed subject, sorted, unique
      subjects = Enum.map(events, & &1.subject)
      assert subjects == Enum.sort(subjects)
      assert subjects == Enum.uniq(subjects)

      # per-subject oracle against the trusted partitions
      before_verdicts = verdicts(before)
      after_verdicts = verdicts(after_partition)

      universe =
        MapSet.union(MapSet.new(Map.keys(before_verdicts)), MapSet.new(Map.keys(after_verdicts)))

      expected =
        universe
        |> Enum.sort()
        |> Enum.flat_map(fn subject ->
          case {Map.get(before_verdicts, subject, :unknown),
                Map.get(after_verdicts, subject, :unknown)} do
            {same, same} -> []
            {from, to} -> [%Event{kind: kind(from, to), subject: subject, from: from, to: to}]
          end
        end)

      assert events == expected,
             "predicates: #{inspect(predicates)}\nbefore facts: #{inspect(facts_before)}\n" <>
               "after facts: #{inspect(facts_after)}\nbefore: #{inspect(before)}\n" <>
               "after: #{inspect(after_partition)}\nevents: #{inspect(events)}"

      # diff applied to before reconstructs after, exactly
      assert before |> apply_events(events) |> verdicts() == after_verdicts

      # the dispatch seam delivers exactly these events; empty dispatches nothing
      case events do
        [] ->
          assert {:ok, []} =
                   Standings.run(query, facts_before, facts_after, SelfSendingDispatcher)

          refute_received {:standings_events, _, _, _}

        changed ->
          assert {:ok, ^changed} =
                   Standings.run(query, facts_before, facts_after, SelfSendingDispatcher)

          assert_received {:standings_events, ^query, ^changed, []}
      end
    end
  end

  # --- generators (same corpus as the S1-54 equivalence properties) ---------------

  defp conjunction_gen do
    bind(boolean(), fn with_var ->
      list_of(probe_gen(with_var), min_length: 1, max_length: 3)
    end)
    |> filter(&single_subject?/1)
  end

  defp single_subject?(predicates) do
    predicates
    |> Enum.map(fn %Predicate{subject: subject} -> subject end)
    |> Enum.uniq()
    |> case do
      [%Var{}] -> true
      [subject] -> not match?(%Var{}, subject)
      _multi -> false
    end
  end

  defp probe_gen(with_var) do
    gen all(
          name <- member_of(Map.keys(@names_values)),
          value <- member_of(Map.fetch!(@names_values, name)),
          op <- member_of([:has, :neg]),
          subject <- subject_gen(with_var)
        ) do
      Predicate.new(op, subject, name, value)
    end
  end

  defp subject_gen(true), do: constant(Var.new(:s))
  defp subject_gen(false), do: member_of(@subjects ++ @context_subjects)

  defp subset_of(candidates) do
    candidates = Enum.uniq(candidates)

    bind(list_of(boolean(), length: length(candidates)), fn include_bits ->
      subset =
        candidates
        |> Enum.zip(include_bits)
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))

      constant(subset)
    end)
  end

  # --- the transition table, restated as the oracle -------------------------------

  defp verdicts(%Membership{in: in_subjects, out: out_subjects, unknown: unknown_subjects}) do
    (Enum.map(in_subjects, &{&1, :in}) ++
       Enum.map(out_subjects, &{&1, :out}) ++
       Enum.map(unknown_subjects, &{&1, :unknown}))
    |> Map.new()
  end

  defp kind(:in, :out), do: :left
  defp kind(:in, :unknown), do: :became_unknown
  defp kind(:out, :in), do: :entered
  defp kind(:out, :unknown), do: :became_unknown
  defp kind(:unknown, :in), do: :entered
  defp kind(:unknown, :out), do: :resolved_out

  defp apply_events(%Membership{} = membership, events) do
    Enum.reduce(events, membership, fn %Event{subject: subject, to: to}, acc ->
      acc
      |> remove(subject)
      |> place(subject, to)
    end)
  end

  defp remove(%Membership{in: i, out: o, unknown: u} = membership, subject) do
    %Membership{
      membership
      | in: List.delete(i, subject),
        out: List.delete(o, subject),
        unknown: List.delete(u, subject)
    }
  end

  defp place(%Membership{} = membership, subject, :in),
    do: %Membership{membership | in: Enum.sort([subject | membership.in])}

  defp place(%Membership{} = membership, subject, :out),
    do: %Membership{membership | out: Enum.sort([subject | membership.out])}

  defp place(%Membership{} = membership, subject, :unknown),
    do: %Membership{membership | unknown: Enum.sort([subject | membership.unknown])}
end
