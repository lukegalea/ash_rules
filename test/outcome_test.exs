# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.OutcomeTest do
  use ExUnit.Case, async: true

  alias AshRules.{Combining, Outcome}

  doctest AshRules.Outcome

  @lattice [:error, :noncompliant, :unknown, :compliant, :not_applicable]

  describe "the lattice" do
    test "has exactly the five outcomes, worst first" do
      assert Outcome.values() == @lattice
    end

    test "rank orders the ordered four and ranks not_applicable nil" do
      assert Outcome.rank(:error) < Outcome.rank(:noncompliant)
      assert Outcome.rank(:noncompliant) < Outcome.rank(:unknown)
      assert Outcome.rank(:unknown) < Outcome.rank(:compliant)
      assert Outcome.rank(:not_applicable) == nil
    end

    test "unknown and error are blocking" do
      assert Outcome.blocking?(:unknown)
      assert Outcome.blocking?(:error)
      refute Outcome.blocking?(:compliant)
      refute Outcome.blocking?(:noncompliant)
      refute Outcome.blocking?(:not_applicable)
    end

    test "merge picks the worse side and not_applicable yields" do
      for left <- @lattice, right <- @lattice do
        expected =
          cond do
            left == :not_applicable -> right
            right == :not_applicable -> left
            Outcome.rank(left) <= Outcome.rank(right) -> left
            true -> right
          end

        assert Outcome.merge(left, right) == expected,
               "merge(#{inspect(left)}, #{inspect(right)})"

        assert Outcome.merge(left, right) == Outcome.merge(right, left)
      end
    end
  end

  describe "deny_overrides (full truth table)" do
    test "every ordered pair" do
      for left <- @lattice, right <- @lattice do
        expected =
          cond do
            left == :not_applicable and right == :not_applicable -> :not_applicable
            left == :not_applicable -> right
            right == :not_applicable -> left
            Outcome.rank(left) <= Outcome.rank(right) -> left
            true -> right
          end

        assert Combining.deny_overrides([left, right]) == expected
      end
    end

    test "any noncompliant or error wins over everything, order-independently" do
      permutations = permute([:compliant, :unknown, :noncompliant])

      for permutation <- permutations do
        assert Combining.deny_overrides(permutation) == :noncompliant
      end

      permutations = permute([:compliant, :error])

      for permutation <- permutations do
        assert Combining.deny_overrides(permutation) == :error
      end
    end
  end

  describe "permit_overrides (full truth table)" do
    test "every ordered pair" do
      for left <- @lattice, right <- @lattice do
        expected =
          cond do
            :compliant in [left, right] -> :compliant
            left == :not_applicable -> right
            right == :not_applicable -> left
            Outcome.rank(left) <= Outcome.rank(right) -> left
            true -> right
          end

        assert Combining.permit_overrides([left, right]) == expected,
               "permit_overrides([#{inspect(left)}, #{inspect(right)}])"
      end
    end

    test "compliant wins over noncompliant, but not over unknown or error" do
      assert Combining.permit_overrides([:noncompliant, :compliant]) == :compliant
      assert Combining.permit_overrides([:unknown, :compliant]) == :compliant
      assert Combining.permit_overrides([:compliant, :compliant]) == :compliant
    end
  end

  describe "first_applicable" do
    test "the first applicable entry decides" do
      assert Combining.first_applicable([:not_applicable, :unknown, :noncompliant]) == :unknown
      assert Combining.first_applicable([:compliant, :noncompliant]) == :compliant
      assert Combining.first_applicable([:error, :compliant]) == :error
    end

    test "all not_applicable stays not_applicable" do
      assert Combining.first_applicable([:not_applicable, :not_applicable]) == :not_applicable
      assert Combining.first_applicable([]) == :not_applicable
    end
  end

  describe "only_one_applicable" do
    test "zero applicable is not_applicable" do
      assert Combining.only_one_applicable([]) == :not_applicable
      assert Combining.only_one_applicable([:not_applicable]) == :not_applicable
    end

    test "exactly one applicable decides" do
      assert Combining.only_one_applicable([:not_applicable, :compliant]) == :compliant
      assert Combining.only_one_applicable([:noncompliant, :not_applicable]) == :noncompliant
    end

    test "more than one applicable is error" do
      assert Combining.only_one_applicable([:compliant, :noncompliant]) == :error
      assert Combining.only_one_applicable([:unknown, :unknown]) == :error
    end
  end

  describe "combine/2 dispatch" do
    test "dispatches to all four algorithms" do
      assert Combining.combine(:deny_overrides, [:noncompliant]) == :noncompliant
      assert Combining.combine(:permit_overrides, [:noncompliant]) == :noncompliant
      assert Combining.combine(:first_applicable, [:noncompliant]) == :noncompliant
      assert Combining.combine(:only_one_applicable, [:noncompliant]) == :noncompliant
    end

    test "refuses unknown algorithms by name" do
      assert_raise ArgumentError, ~r/unknown combining algorithm :bogus/, fn ->
        Combining.combine(:bogus, [:compliant])
      end
    end
  end

  defp permute(list) when length(list) <= 1, do: [list]

  defp permute(list) do
    for elem <- list, rest <- permute(list -- [elem]) do
      [elem | rest]
    end
  end
end
