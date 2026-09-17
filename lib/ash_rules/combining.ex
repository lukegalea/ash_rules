# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Combining do
  @moduledoc """
  XACML-derived combining algorithms over outcome lists.

  A rule set declares one algorithm; `AshRules.Ir.Bundle` carries it and the
  evaluators apply it to produce a requirement's overall outcome from its
  per-rule outcomes. `deny_overrides` is the default, because for compliance
  the question "does anything break?" is the question.

  * `deny_overrides` — any applicable `:noncompliant`/`:error` wins; worst
    case otherwise; `:not_applicable` only when nothing applies.
  * `permit_overrides` — any applicable `:compliant` wins among non-blocking
    outcomes; `:unknown`/`:error`/`:noncompliant` still dominate when no
    applicable rule is compliant.
  * `first_applicable` — the outcome of the first applicable entry, in the
    order given.
  * `only_one_applicable` — exactly one applicable entry decides; more than
    one is `:error` (the rule set is misconfigured — two rules claiming sole
    jurisdiction is a bug, not a tie to break); none is `:not_applicable`.

  All four are pure functions over outcome lists and all four are covered by
  full truth-table tests over the lattice, not samples.
  """

  alias AshRules.Outcome

  @type algorithm() ::
          :deny_overrides | :permit_overrides | :first_applicable | :only_one_applicable

  @algorithms [:deny_overrides, :permit_overrides, :first_applicable, :only_one_applicable]

  @doc "The combining algorithms a rule set may declare."
  @spec algorithms() :: [algorithm(), ...]
  def algorithms, do: @algorithms

  @doc "The default algorithm when a rule set declares none."
  @spec default() :: algorithm()
  def default, do: :deny_overrides

  @doc "Combines a list of outcomes with the given algorithm."
  @spec combine(algorithm(), [Outcome.t()]) :: Outcome.t()
  def combine(algorithm, outcomes)

  def combine(:deny_overrides, outcomes), do: deny_overrides(outcomes)
  def combine(:permit_overrides, outcomes), do: permit_overrides(outcomes)
  def combine(:first_applicable, outcomes), do: first_applicable(outcomes)
  def combine(:only_one_applicable, outcomes), do: only_one_applicable(outcomes)

  def combine(algorithm, _outcomes) do
    raise ArgumentError,
          "unknown combining algorithm #{inspect(algorithm)}. " <>
            "Use one of: #{inspect(@algorithms)}"
  end

  @doc "`deny_overrides`: the worst applicable outcome wins."
  @spec deny_overrides([Outcome.t()]) :: Outcome.t()
  def deny_overrides(outcomes), do: worst(outcomes)

  @doc """
  `permit_overrides`: `:compliant` wins unless only blocking outcomes remain.
  """
  @spec permit_overrides([Outcome.t()]) :: Outcome.t()
  def permit_overrides(outcomes) do
    applicable = Enum.reject(outcomes, &(&1 == :not_applicable))

    if Enum.any?(applicable, &(&1 == :compliant)) do
      :compliant
    else
      worst(applicable)
    end
  end

  @doc "`first_applicable`: the first non-`:not_applicable` outcome decides."
  @spec first_applicable([Outcome.t()]) :: Outcome.t()
  def first_applicable(outcomes) do
    case Enum.find(outcomes, &(&1 != :not_applicable)) do
      nil -> :not_applicable
      outcome -> outcome
    end
  end

  @doc "`only_one_applicable`: one applicable outcome decides, more is `:error`."
  @spec only_one_applicable([Outcome.t()]) :: Outcome.t()
  def only_one_applicable(outcomes) do
    applicable = Enum.reject(outcomes, &(&1 == :not_applicable))

    case applicable do
      [] -> :not_applicable
      [only] -> only
      _multiple -> :error
    end
  end

  defp worst(outcomes) do
    Enum.reduce(outcomes, :not_applicable, &Outcome.merge/2)
  end
end
