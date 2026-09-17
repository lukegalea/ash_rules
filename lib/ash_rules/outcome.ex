# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Outcome do
  @moduledoc """
  The outcome lattice every rule evaluation and every aggregation produces.

  The lattice has five values, ordered from worst to best:

      :error > :noncompliant > :unknown > :compliant

  with `:not_applicable` standing outside the order: it participates in
  aggregation only in the degenerate case where *every* input is
  `:not_applicable`, in which case the aggregate is `:not_applicable` too.

  The two values that carry no positive information — `:unknown` (facts missing)
  and `:error` (evaluation failed) — never collapse to `:compliant`. That
  invariant is the whole point of having a lattice instead of booleans, and it
  is asserted by the property suite, not by this docstring.
  """

  @typedoc "The outcome of a rule evaluation or of an aggregation."
  @type t() ::
          :compliant | :noncompliant | :not_applicable | :unknown | :error

  @outcomes [:error, :noncompliant, :unknown, :compliant, :not_applicable]

  @doc "All outcomes, worst first."
  @spec values() :: [t(), ...]
  def values, do: @outcomes

  @doc "The outcome's position in the lattice: 0 is worst, 3 is best, N/A is nil."
  @spec rank(t()) :: non_neg_integer() | nil
  def rank(:error), do: 0
  def rank(:noncompliant), do: 1
  def rank(:unknown), do: 2
  def rank(:compliant), do: 3
  def rank(:not_applicable), do: nil

  @doc """
  Merges two outcomes: the worse one wins, `:not_applicable` yields to
  everything.
  """
  @spec merge(t(), t()) :: t()
  def merge(left, right)

  def merge(:not_applicable, other), do: other
  def merge(other, :not_applicable), do: other
  def merge(left, right), do: worse_of(left, right)

  @doc "The worse of two outcomes. `:not_applicable` inputs return the other side."
  @spec worse_of(t(), t()) :: t()
  def worse_of(left, right) do
    if rank_or_max(left) <= rank_or_max(right), do: left, else: right
  end

  @doc "True if the outcome is one of the two that never collapse to compliant."
  @spec blocking?(t()) :: boolean()
  def blocking?(:unknown), do: true
  def blocking?(:error), do: true
  def blocking?(_), do: false

  @doc "Validates an untrusted term as an outcome (used by the IR decoder)."
  @spec validate(term()) :: {:ok, t()} | :error
  def validate(value) when value in @outcomes, do: {:ok, value}
  def validate(_), do: :error

  defp rank_or_max(outcome) do
    case rank(outcome) do
      nil -> 4
      rank -> rank
    end
  end
end
