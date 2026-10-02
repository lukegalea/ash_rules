# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.SetEvaluatorTest do
  @moduledoc """
  The set evaluator's membership semantics, worked example by example:
  the three-valued partition per ADR 0048, absence resolution identical to
  `AshRules.Facts.absence/2`, strict value equality, and every compile-time
  refusal. The randomized equivalence proof lives in
  `AshRules.SetMembershipPropertyTest`.
  """

  use ExUnit.Case, async: true

  alias AshRules.Evaluator.Set
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var
  alias AshRules.TestSupport.FactRecords
  alias AshRules.TestSupport.RuleSets

  @schema RuleSets.Property.__bundle__().fact_schema
  @resource FactRecords

  defp has(subject, name, value), do: Predicate.new(:has, subject, name, value)
  defp neg(subject, name, value), do: Predicate.new(:neg, subject, name, value)
  defp var, do: Var.new(:s)

  # The one-shot membership/4 with the test schema pinned.
  defp membership(predicates, source, opts \\ []),
    do: Set.membership(@schema, predicates, source, opts)

  # Asserts the partition holds exactly these subjects per partition.
  defp assert_partition({:ok, membership}, expected) do
    assert %Set.Membership{} = membership

    for partition <- ~w(in out unknown)a do
      assert Map.fetch!(membership, partition) == Keyword.get(expected, partition, []),
             "expected #{partition} = #{inspect(Keyword.get(expected, partition, []))}, " <>
               "got #{inspect(Map.fetch!(membership, partition))}"
    end

    membership
  end

  describe "membership over in-memory facts" do
    test "the empty fact set partitions nothing" do
      assert_partition(membership([has(var(), :p_b, true)], []), in: [], out: [], unknown: [])
    end

    test "a single fact decides membership exactly" do
      facts = [{:s1, :p_b, true}]

      assert_partition(membership([has(var(), :p_b, true)], facts), in: [:s1])

      assert_partition(membership([has(var(), :p_b, false)], facts), out: [:s1])

      assert_partition(membership([neg(var(), :p_b, true)], facts), out: [:s1])

      assert_partition(membership([neg(var(), :p_b, false)], facts), in: [:s1])
    end

    test "absence under missing: :unknown lands in unknown, never folded either way" do
      facts = [{:s1, :owner, :customer}]

      # No p_b fact at all: unknown, for the true probe…
      assert_partition(membership([has(var(), :p_b, true)], facts), unknown: [:s1])

      # …for the false probe (missing: :unknown dominates the synthesized
      # false: Facts.absence/2 checks missing before value)…
      assert_partition(membership([has(var(), :p_b, false)], facts), unknown: [:s1])

      # …and for negation.
      assert_partition(membership([neg(var(), :p_b, true)], facts), unknown: [:s1])
    end

    test "absence under missing: :false synthesizes the false value" do
      # No p_d facts anywhere: absence *is* false.
      facts = [{:s1, :owner, :customer}]

      assert_partition(membership([has(var(), :p_d, false)], facts), in: [:s1])

      assert_partition(membership([neg(var(), :p_d, false)], facts), out: [:s1])

      assert_partition(membership([has(var(), :p_d, true)], facts), out: [:s1])

      assert_partition(membership([neg(var(), :p_d, true)], facts), in: [:s1])
    end

    test "absence under missing: :no_fact is an expected mismatch" do
      facts = [{:s1, :owner, :customer}]

      assert_partition(membership([has(var(), :p_c, 0)], facts), out: [:s1])

      assert_partition(membership([neg(var(), :p_c, 0)], facts), in: [:s1])
    end

    test "a conjunction scans probes in clause order; the first deciding probe wins" do
      facts = [{:s1, :owner, :customer}]

      # Probe 1 definitively fails (absent p_d, true): out, even though
      # probe 2 would be unknown.
      assert_partition(
        membership([has(var(), :p_d, true), has(var(), :p_b, true)], facts),
        out: [:s1]
      )

      # Reversed: unknown now comes first and dominates.
      assert_partition(
        membership([has(var(), :p_b, true), has(var(), :p_d, true)], facts),
        unknown: [:s1]
      )

      # Both hold: in.
      assert_partition(
        membership(
          [has(var(), :owner, :customer), has(var(), :p_d, false)],
          facts ++ [{:s1, :p_d, false}]
        ),
        in: [:s1]
      )
    end

    test "the set ranges over the designated variable's subjects" do
      facts = [
        {:s1, :owner, :customer},
        {:s1, :p_d, true},
        {:s2, :owner, :customer},
        {:s2, :p_d, false},
        {:s3, :owner, :other}
      ]

      # Accounts owned by the customer that do NOT have p_d true: s2 in,
      # s1 out (the fact exists), s3 out (wrong owner).
      assert_partition(
        membership([has(var(), :owner, :customer), neg(var(), :p_d, true)], facts),
        in: [:s2],
        out: [:s1, :s3]
      )
    end

    test "a probe about another ground subject is a context condition" do
      facts = [{:s1, :owner, :customer}, {:s2, :owner, :customer}]

      # The vendor predicate is absent: mismatch (missing: :false, value
      # true) — every member of the set is out, regardless of its own facts.
      assert_partition(
        membership([has(var(), :owner, :customer), has(:vendor, :p_d, true)], facts),
        out: [:s1, :s2]
      )

      # Synthesized false: the context condition holds — everyone stays in
      # (the vendor has no p_d fact and absence resolves as false).
      assert_partition(
        membership([has(var(), :owner, :customer), has(:vendor, :p_d, false)], facts),
        in: [:s1, :s2]
      )

      # Unknown context condition: the whole set is unknown.
      assert_partition(
        membership([has(var(), :owner, :customer), has(:vendor, :p_b, true)], facts),
        unknown: [:s1, :s2]
      )
    end

    test "the partitions are disjoint and cover the universe" do
      facts = [
        {:s1, :p_b, true},
        {:s2, :p_b, false},
        {:s3, :owner, :customer}
      ]

      {:ok, membership} = membership([has(var(), :p_b, true)], facts)
      in_set = MapSet.new(membership.in)
      out_set = MapSet.new(membership.out)
      unknown_set = MapSet.new(membership.unknown)

      assert MapSet.disjoint?(in_set, out_set)
      assert MapSet.disjoint?(in_set, unknown_set)
      assert MapSet.disjoint?(out_set, unknown_set)

      assert MapSet.union(in_set, MapSet.union(out_set, unknown_set)) ==
               MapSet.new([:s1, :s2, :s3])
    end

    test "value equality is the IR's strict equality: 1 does not match 1.0" do
      facts = [{:s1, :p_n, 1.0}]

      assert_partition(membership([has(var(), :p_n, 1)], facts), out: [:s1])

      assert_partition(membership([has(var(), :p_n, 1.0)], facts), in: [:s1])
    end
  end

  describe "membership over a fact resource" do
    test "partitions identically to the facts path" do
      facts = [
        {:s1, :owner, :customer},
        {:s1, :p_b, true},
        {:s2, :owner, :customer},
        {:s3, :p_n, 1.0},
        {:s3, :owner, :customer}
      ]

      predicates = [has(var(), :owner, :customer), neg(var(), :p_b, true)]

      FactRecords.seed!(facts)

      try do
        assert {:ok, from_facts} = membership(predicates, facts)
        assert {:ok, from_resource} = membership(predicates, @resource)
        assert from_resource == from_facts
      after
        FactRecords.wipe!()
      end
    end

    test "the compiled query's value narrow is re-verified strictly" do
      # The ETS layer's equality coerces 1 == 1.0; the set evaluator must
      # not. The probe says 1, the fact says 1.0: out on the resource path.
      FactRecords.seed!([{:s1, :p_n, 1.0}])

      try do
        assert_partition(membership([has(var(), :p_n, 1)], @resource), out: [:s1])
      after
        FactRecords.wipe!()
      end
    end

    test "an empty table partitions nothing" do
      assert_partition(membership([has(var(), :p_b, true)], @resource),
        in: [],
        out: [],
        unknown: []
      )
    end

    test "read opts are forwarded (authorize?: false)" do
      FactRecords.seed!([{:s1, :p_d, false}])

      try do
        assert_partition(
          membership([has(var(), :p_d, false)], @resource, authorize?: false),
          in: [:s1]
        )
      after
        FactRecords.wipe!()
      end
    end

    test "a module that is not a fact resource is refused" do
      assert {:error, message} = membership([has(var(), :p_d, false)], RuleSets.Property)
      assert message =~ "is not an Ash resource"
    end
  end

  describe "compile refusals" do
    test "an empty conjunction" do
      assert {:error, message} = Set.compile(@schema, [])
      assert message =~ "at least one predicate"
    end

    test "non-predicate input" do
      assert {:error, message} = Set.compile(@schema, [:junk])
      assert message =~ "%AshRules.Ir.Predicate{}"
    end

    test "two distinct subject variables" do
      predicates = [has(var(), :owner, :customer), has(Var.new(:t), :p_d, true)]

      assert {:error, message} = Set.compile(@schema, predicates)
      assert message =~ "one subject variable"
    end

    test "a variable in a value position" do
      assert {:error, message} = Set.compile(@schema, [has(var(), :owner, Var.new(:t))])
      assert message =~ "value"
      assert message =~ "ground"
    end

    test "a ground-only conjunction probing two subjects" do
      predicates = [has(:s1, :p_d, true), has(:s2, :p_d, true)]

      assert {:error, message} = Set.compile(@schema, predicates)
      assert message =~ "exactly one subject"
    end

    test "an undeclared predicate" do
      assert {:error, message} = Set.compile(@schema, [has(var(), :nope, true)])
      assert message =~ "not in the fact schema"
    end

    test "a value that does not type-check" do
      assert {:error, message} = Set.compile(@schema, [has(var(), :p_c, true)])
      assert message =~ "does not type-check against :integer"

      assert {:error, message} = Set.compile(@schema, [has(var(), :p_a, :bogus)])
      assert message =~ "does not type-check against :atom"
      assert message =~ "one_of"
    end
  end

  describe "entry points" do
    test "membership/4 accepts a bundle or a schema, compiling and running in one step" do
      facts = [{:s1, :p_d, false}]
      predicates = [has(var(), :p_d, false)]

      assert {:ok, from_schema} = Set.membership(@schema, predicates, facts, [])

      assert {:ok, from_bundle} =
               Set.membership(RuleSets.Property.__bundle__(), predicates, facts, [])

      assert from_bundle == from_schema
      assert from_schema.in == [:s1]
      assert from_schema.out == []
      assert from_schema.unknown == []
    end

    test "AshRules.membership/4 evaluates a bundle's schema over a set" do
      schema = RuleSets.KYC.__bundle__().fact_schema

      predicates = [has(var(), :status, :active), neg(var(), :has_valid_kyc, true)]

      facts = [
        {:s1, :status, :active},
        {:s1, :has_valid_kyc, true},
        {:s2, :status, :active},
        {:s2, :has_valid_kyc, false}
      ]

      assert {:ok, membership} = AshRules.membership(schema, predicates, facts)
      assert membership.in == [:s2]
      assert membership.out == [:s1]
      assert membership.unknown == []
    end

    test "AshRules.membership/4 takes a rule set module directly" do
      facts = [{:s1, :status, :active}, {:s1, :has_valid_kyc, true}]
      predicates = [neg(var(), :has_valid_kyc, true)]

      assert {:ok, membership} = AshRules.membership(RuleSets.KYC, predicates, facts)
      assert membership.in == []
      assert membership.out == [:s1]
    end
  end
end
