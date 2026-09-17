# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Facts do
  @moduledoc """
  Working memory: fact triples validated against a bundle's fact schema.

  Facts are `{subject, predicate, value}` triples. Both evaluators go through
  `prepare/2` before evaluating, so the schema contract is enforced exactly
  once and identically:

    * a fact whose predicate is not in the schema is an error — name the fact
      and the fix (declare it or drop it);
    * a fact whose value violates the schema's type or `one_of` is an error.

  Absence semantics live on the schema entries (`AshRules.Ir.Fact`), and the
  `:false`/`:no_fact` handling is implemented here once so the direct and
  Wongi evaluators cannot drift apart: ground probes on absent facts resolve
  through `absence/3`, which both adapters call.
  """

  alias AshRules.Ir.Fact
  alias AshRules.Ir.FactSchema

  @type triple() :: {term(), atom(), term()}

  defstruct [:triples, :by_predicate, :schema]

  @type t() :: %__MODULE__{
          triples: MapSet.t(triple()),
          by_predicate: %{atom() => [triple()]},
          schema: FactSchema.t()
        }

  @doc """
  Validates and indexes facts against a fact schema.

  Returns `{:ok, facts}` with triples sorted for determinism, or
  `{:error, message}` naming the offending fact and the fix.
  """
  @spec prepare(FactSchema.t() | AshRules.Ir.Bundle.t(), [triple()]) ::
          {:ok, t()} | {:error, String.t()}
  def prepare(%AshRules.Ir.Bundle{fact_schema: schema}, facts),
    do: prepare(schema, facts)

  def prepare(%FactSchema{} = schema, facts) when is_list(facts) do
    Enum.reduce_while(facts, {:ok, []}, fn triple, {:ok, acc} ->
      case validate_triple(schema, triple) do
        :ok -> {:cont, {:ok, [triple | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, facts} ->
        facts = Enum.sort(facts)

        {:ok,
         %__MODULE__{
           triples: MapSet.new(facts),
           by_predicate: index_by_predicate(facts),
           schema: schema
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  def prepare(_schema, facts),
    do:
      {:error,
       "facts must be a list of {subject, predicate, value} triples, got #{inspect(facts)}"}

  @doc "True if the exact triple is in working memory."
  @spec member?(t(), triple()) :: boolean()
  def member?(%__MODULE__{triples: triples}, triple), do: MapSet.member?(triples, triple)

  @doc """
  True if any fact with this subject and predicate exists, whatever the value.

  This distinguishes "the value we asked about is not there" (a real
  mismatch — the predicate has data) from "the predicate has no data at all"
  (absence semantics apply).
  """
  @spec any_fact?(t(), term(), atom()) :: boolean()
  def any_fact?(%__MODULE__{by_predicate: by_predicate}, subject, name) do
    by_predicate
    |> Map.get(name, [])
    |> Enum.any?(fn {candidate_subject, _name, _value} ->
      AshRules.Ir.values_equal?(candidate_subject, subject)
    end)
  end

  @doc "All triples with the given predicate, sorted."
  @spec with_predicate(t(), atom()) :: [triple()]
  def with_predicate(%__MODULE__{by_predicate: by_predicate}, name) do
    Map.get(by_predicate, name, [])
  end

  @doc """
  Resolves an absent ground probe through the schema's absence semantics.

  * `:unknown` — `{:absent, :unknown}`; the caller turns the rule `:unknown`.
  * `:false` / `:no_fact` — `{:absent, :as_false}` when the probe's value is
    `false` (the synthesized triple behaves as present), `{:absent, :mismatch}`
    otherwise.
  """
  @spec absence(Fact.t(), triple()) :: {:absent, :unknown | :as_false | :mismatch}
  def absence(%Fact{missing: :unknown}, _triple), do: {:absent, :unknown}

  def absence(%Fact{missing: missing}, {_subject, _name, value})
      when missing in [false, :no_fact] do
    if value == false, do: {:absent, :as_false}, else: {:absent, :mismatch}
  end

  @doc "True if the schema entry reports absence in the result's missing facts."
  @spec reports_absence?(Fact.t()) :: boolean()
  def reports_absence?(%Fact{missing: missing}), do: missing in [false, :unknown]

  defp validate_triple(schema, {_subject, name, value} = triple)
       when is_atom(name) do
    case FactSchema.fetch(schema, name) do
      :error ->
        {:error,
         "fact #{inspect(triple)}: predicate #{inspect(name)} is not in the fact schema. " <>
           "Declare it with `fact #{inspect(name)}, :type` in fact_schema, or drop the fact"}

      {:ok, fact} ->
        if Fact.valid_value?(fact, value) do
          :ok
        else
          {:error,
           "fact #{inspect(triple)}: value #{inspect(value)} does not type-check against " <>
             "#{inspect(fact.type)}" <> one_of_hint(fact)}
        end
    end
  end

  defp validate_triple(_schema, other) do
    {:error,
     "facts must be {subject, predicate, value} triples with atom predicates, got #{inspect(other)}"}
  end

  defp one_of_hint(%{one_of: nil}), do: ""
  defp one_of_hint(%{one_of: one_of}), do: " (one_of: #{inspect(one_of)})"

  defp index_by_predicate(facts) do
    facts
    |> Enum.group_by(fn {_subject, name, _value} -> name end)
    |> Map.new(fn {name, triples} -> {name, Enum.sort(triples)} end)
  end
end
