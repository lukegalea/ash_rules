# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshRules.Evaluator.Direct
  alias AshRules.Evaluator.Wongi
  alias AshRules.Outcome
  alias AshRules.TestSupport.RuleSets.Property

  @moduletag :property

  @bundle Property.__bundle__()
  @lattice Outcome.values()
  @subjects [:customer, :acct1, :acct2]

  @predicate_values [
    p_a: [:x, :y, :z],
    p_b: [true, false],
    p_c: [0, 1],
    p_d: [true, false],
    owner: [:customer, :other]
  ]

  @candidate_facts Enum.flat_map(@subjects, fn subject ->
                     Enum.flat_map(@predicate_values, fn {predicate, values} ->
                       Enum.map(values, &{subject, predicate, &1})
                     end)
                   end)

  @junk_fact {:customer, :p_c, "not an integer"}

  property "evaluation never crashes and returns a well-formed result" do
    check all(facts <- subset_of(@candidate_facts)) do
      assert {:ok, result} = Direct.evaluate(@bundle, facts, [])
      assert result.overall in @lattice
      assert length(result.requirements) == length(@bundle.rules)

      for requirement <- result.requirements do
        assert requirement.outcome in @lattice
        assert requirement.rule_revision == "1"

        if requirement.outcome == :unknown do
          refute requirement.missing_facts == [],
                 "an unknown requirement must name what is missing"
        end

        if requirement.outcome == :noncompliant do
          assert requirement.gap != nil, "a finding must carry combining metadata"
        end
      end
    end
  end

  property "evaluation is deterministic" do
    check all(facts <- subset_of(@candidate_facts)) do
      {:ok, first} = Direct.evaluate(@bundle, facts, [])
      {:ok, second} = Direct.evaluate(@bundle, facts, [])
      assert first == second
    end
  end

  property "fact order does not change the result" do
    check all(facts <- subset_of(@candidate_facts)) do
      {:ok, straight} = Direct.evaluate(@bundle, facts, [])
      {:ok, shuffled} = Direct.evaluate(@bundle, Enum.reverse(facts), [])
      assert straight == shuffled
    end
  end

  property "the overall outcome never collapses to compliant on unknown or error" do
    check all(facts <- subset_of(@candidate_facts)) do
      {:ok, result} = Direct.evaluate(@bundle, facts, [])

      unknowns = Enum.filter(result.requirements, &(&1.outcome == :unknown))

      if unknowns != [] do
        refute result.overall == :compliant,
               "unknown requirements must block a compliant overall outcome"
      end
    end
  end

  property "schema-violating facts are always refused" do
    check all(
            facts <- subset_of(@candidate_facts),
            with_junk <- boolean()
          ) do
      input =
        if with_junk, do: [@junk_fact | Enum.reject(facts, &(&1 == @junk_fact))], else: facts

      if with_junk do
        assert {:error, message} = Direct.evaluate(@bundle, input, [])
        assert message =~ "does not type-check against :integer"
      else
        assert {:ok, _result} = Direct.evaluate(@bundle, input, [])
      end
    end
  end

  property "direct and wongi evaluators agree on the whole corpus" do
    check all(facts <- subset_of(@candidate_facts)) do
      {:ok, direct} = Direct.evaluate(@bundle, facts, [])
      {:ok, wongi} = Wongi.evaluate(@bundle, facts, [])

      decisions =
        Enum.map(direct.requirements, fn requirement ->
          Map.take(requirement, [:rule_id, :outcome, :bindings, :missing_facts, :message])
        end)

      wongi_decisions =
        Enum.map(wongi.requirements, fn requirement ->
          Map.take(requirement, [:rule_id, :outcome, :bindings, :missing_facts, :message])
        end)

      assert wongi_decisions == decisions
      assert wongi.derived_facts == direct.derived_facts
      assert wongi.missing_facts == direct.missing_facts
      assert wongi.overall == direct.overall

      for {d, w} <- Enum.zip(direct.requirements, wongi.requirements),
          d.outcome == :noncompliant do
        assert w.consumed_facts == d.consumed_facts
      end
    end
  end

  # --- generators ---------------------------------------------------------------

  # An unbiased, shrinking-friendly subset generator: one include/exclude bit
  # per candidate, always producing a deterministic list for a given value.
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
end
