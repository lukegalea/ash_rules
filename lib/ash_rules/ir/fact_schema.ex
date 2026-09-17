# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.FactSchema do
  @moduledoc """
  The fact schema half of a bundle: what predicates exist, what values they
  carry, and what absence means.

  A schema is a list of `AshRules.Ir.Fact` entries. Both evaluators validate
  working memory against it before evaluating: a fact whose predicate is not in
  the schema, or whose value violates the schema, is a hard error — feeding an
  evaluator unvalidated facts is how "compliant" becomes a lie.
  """

  alias AshRules.Ir.Fact

  defstruct [:facts]

  @type t() :: %__MODULE__{facts: [Fact.t()]}

  @doc "Builds a schema from fact entries; order is normalized to name order."
  @spec new([Fact.t()]) :: t()
  def new(facts), do: %__MODULE__{facts: Enum.sort_by(facts, & &1.name)}

  @doc "The entry for a predicate name, if the schema declares one."
  @spec fetch(t(), atom()) :: {:ok, Fact.t()} | :error
  def fetch(%__MODULE__{facts: facts}, name) do
    Enum.find_value(facts, :error, fn
      %Fact{name: ^name} = fact -> {:ok, fact}
      _ -> nil
    end)
  end

  @doc "True if the schema declares the predicate."
  @spec declares?(t(), atom()) :: boolean()
  def declares?(%__MODULE__{facts: facts}, name) do
    Enum.any?(facts, &match?(%Fact{name: ^name}, &1))
  end

  @doc "The JSON list form, for the codec and canonical hashing."
  @spec to_json(t()) :: [map()]
  def to_json(%__MODULE__{facts: facts}), do: Enum.map(facts, &Fact.to_json/1)

  @doc "Decodes the JSON list form; every entry is validated on the way in."
  @spec from_json([map()]) :: {:ok, t()} | {:error, String.t()}
  def from_json(facts) when is_list(facts) do
    facts
    |> Enum.reduce_while({:ok, []}, fn json, {:ok, acc} ->
      case Fact.from_json(json) do
        {:ok, fact} -> {:cont, {:ok, [fact | acc]}}
        {:error, error} -> {:halt, {:error, "fact schema entry: #{error}"}}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, new(Enum.reverse(facts))}
      {:error, error} -> {:error, error}
    end
  end

  def from_json(_), do: {:error, "fact schema must be a list"}
end
