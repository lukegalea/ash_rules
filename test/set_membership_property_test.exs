# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.SetMembershipPropertyTest do
  @moduledoc """
  The equivalence property of ADR 0048: **for every subject, set membership
  equals the per-subject outcome.**

  For randomly generated IR predicates (conjunctions over the designated
  variable, context probes, `has`/`neg`, every absence semantics, mixed
  numeric values) and randomly generated fact sets — including the empty set
  and single-fact sets, which the subset generator ranges over naturally —
  the set evaluator's `in`/`out`/`unknown` partition must equal, for every
  subject in the universe, the direct evaluator's per-subject evaluation of
  the same predicates over the same facts. The oracle grounds the
  conjunction at the subject and evaluates it as a one-rule bundle through
  `AshRules.Evaluator.Direct`: all probes hold → fired → `in`; a probe
  definitively fails → `not_applicable` → `out`; a probe hits absent
  `missing: :unknown` data → `unknown`. The resource path (compiled Ash
  queries over the ETS fact table) must additionally produce the identical
  partition, proving the compiled queries agree with the in-memory path.

  Seeds: StreamData drives properties from the ExUnit seed, so a failure
  reproduces with `mix test --seed <n>` (the seed is printed with the
  failure).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshRules.Evaluator.Direct
  alias AshRules.Evaluator.Set
  alias AshRules.Ir.Bundle
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var
  alias AshRules.TestSupport.FactRecords
  alias AshRules.TestSupport.RuleSets

  @moduletag :property

  @schema RuleSets.Property.__bundle__().fact_schema
  @resource FactRecords

  # Every fact type and every absence semantics the IR supports:
  # :atom (with one_of), :boolean, :integer, :number (floats for the
  # strict-equality trap), missing: :false / :unknown / :no_fact.
  @names_values %{
    p_a: [:x, :y, :z],
    p_b: [true, false],
    p_c: [0, 1],
    p_d: [true, false],
    p_n: [0, 1, 0.0, 1.0],
    owner: [:customer, :other]
  }

  @subjects [:s1, :s2, :s3, :s4]

  # Context subjects never appear in generated facts, so context probes
  # exercise every absence branch over a fixed foreign subject.
  @context_subjects [:customer, :vendor]

  @candidate_facts Enum.flat_map(@subjects, fn subject ->
                     Enum.flat_map(@names_values, fn {name, values} ->
                       Enum.map(values, &{subject, name, &1})
                     end)
                   end)

  property "set membership equals the direct evaluator's per-subject outcome" do
    check all(predicates <- conjunction_gen(), facts <- subset_of(@candidate_facts)) do
      {:ok, membership} = Set.membership(@schema, predicates, facts, [])
      universe = universe_of(facts)

      assert_partitions_cover_universe(membership, universe)

      for subject <- universe do
        expected = direct_verdict(predicates, subject, facts)

        actual =
          cond do
            subject in membership.in -> :in
            subject in membership.out -> :out
            subject in membership.unknown -> :unknown
            true -> flunk("subject #{inspect(subject)} missing from the partition")
          end

        assert actual == expected,
               "subject #{inspect(subject)}: set says #{inspect(actual)}, direct says " <>
                 "#{inspect(expected)}\npredicates: #{inspect(predicates)}\nfacts: #{inspect(facts)}\n" <>
                 "membership: #{inspect(membership)}"
      end
    end
  end

  property "the compiled-query resource path partitions identically to the facts path" do
    check all(predicates <- conjunction_gen(), facts <- subset_of(@candidate_facts)) do
      @resource.seed!(facts)

      try do
        assert {:ok, from_facts} = Set.membership(@schema, predicates, facts, [])
        assert {:ok, from_resource} = Set.membership(@schema, predicates, @resource, [])

        assert from_resource == from_facts,
               "predicates: #{inspect(predicates)}\nfacts: #{inspect(facts)}\n" <>
                 "facts path: #{inspect(from_facts)}\nresource path: #{inspect(from_resource)}"
      after
        @resource.wipe!()
      end
    end
  end

  # --- generators ---------------------------------------------------------------

  # A conjunction of 1..3 probes. Either every probe is about the one
  # designated variable `var(:s)`, or all probes are ground; ground probes
  # may name any subject (facts subjects or foreign context subjects).
  # Values are always ground and type-correct against the schema. Shapes the
  # set evaluator refuses (two variables, mixed subjects without a variable)
  # are filtered out — the refusals themselves are covered deterministically
  # in `AshRules.SetEvaluatorTest`.
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

  # An unbiased, shrinking-friendly subset generator (same shape as
  # AshRules.PropertyTest): one include/exclude bit per candidate, so the
  # empty set and single-fact sets are always in range.
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

  # --- the oracle: the direct evaluator, per subject ------------------------------

  defp universe_of(facts), do: facts |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

  defp assert_partitions_cover_universe(membership, universe) do
    in_set = MapSet.new(membership.in)
    out_set = MapSet.new(membership.out)
    unknown_set = MapSet.new(membership.unknown)

    assert MapSet.disjoint?(in_set, out_set), "in and out overlap: #{inspect(membership)}"
    assert MapSet.disjoint?(in_set, unknown_set), "in and unknown overlap: #{inspect(membership)}"

    assert MapSet.disjoint?(out_set, unknown_set),
           "out and unknown overlap: #{inspect(membership)}"

    assert MapSet.union(in_set, MapSet.union(out_set, unknown_set)) == MapSet.new(universe),
           "the partitions do not cover the universe #{inspect(universe)}: #{inspect(membership)}"
  end

  # Grounds the conjunction at `subject` and evaluates it through the direct
  # evaluator as a one-rule bundle: the conjunction is the applicability,
  # failure conditions are empty, so
  #
  #   * every probe holds  -> the rule fires   -> :in
  #   * a probe fails      -> :not_applicable  -> :out
  #   * a probe is unknown -> :unknown         -> :unknown
  #
  # which is the direct evaluator's per-subject outcome for the set
  # expression, clause order and absence semantics included.
  defp direct_verdict(predicates, subject, facts) do
    grounded =
      Enum.map(predicates, fn %Predicate{op: op, subject: probe_subject, name: name, value: value} ->
        resolved_subject = if match?(%Var{}, probe_subject), do: subject, else: probe_subject
        Predicate.new(op, resolved_subject, name, value)
      end)

    rule =
      AshRules.Ir.Rule.new(
        id: "set.equivalence_probe",
        name: "set equivalence probe",
        applicability: grounded,
        failure_conditions: [],
        outcome: OutcomeDeclaration.new(:noncompliant, "set.equivalence_probe")
      )

    bundle = Bundle.new([rule], @schema)
    assert {:ok, result} = Direct.evaluate(bundle, facts, [])
    requirement = hd(result.requirements)

    case requirement.outcome do
      :noncompliant -> :in
      :not_applicable -> :out
      :unknown -> :unknown
      other -> flunk("oracle produced #{inspect(other)} for subject #{inspect(subject)}")
    end
  end
end
