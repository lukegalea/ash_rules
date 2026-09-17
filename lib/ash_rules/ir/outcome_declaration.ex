# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.OutcomeDeclaration do
  @moduledoc """
  What a rule asserts when its failure conditions all hold.

  `outcome` is the asserted result — almost always `:noncompliant`; `:unknown`
  and `:error` are legal for rules that fire on data conditions that make
  compliance undecidable or evaluation inconsistent. `:compliant` and
  `:not_applicable` are refused: a rule that fires cannot assert a good state,
  and the verifiers say so.

  `gap` is the combining metadata: the control (or gap) reference the finding
  is filed under. A `:noncompliant` outcome without one is refused — an
  unfiled finding cannot be waived, tracked or aggregated.
  """

  defstruct [:outcome, :gap, __spark_metadata__: nil]

  @type t() :: %__MODULE__{outcome: AshRules.Outcome.t(), gap: String.t() | nil}

  @allowed [:noncompliant, :unknown, :error]

  @doc "The outcomes a firing rule may assert."
  @spec allowed() :: [AshRules.Outcome.t(), ...]
  def allowed, do: @allowed

  @doc "Builds a declaration."
  @spec new(AshRules.Outcome.t(), String.t() | nil) :: t()
  def new(outcome, gap) when outcome in @allowed do
    %__MODULE__{outcome: outcome, gap: gap}
  end

  @doc "The JSON object form, for the codec and canonical hashing."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{outcome: outcome, gap: gap}) do
    %{"outcome" => Atom.to_string(outcome)}
    |> put_if("gap", gap)
  end

  @doc "Decodes the JSON object form."
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"outcome" => outcome} = json) when is_binary(outcome) do
    case AshRules.Outcome.validate(String.to_existing_atom(outcome)) do
      {:ok, outcome} ->
        if outcome in @allowed do
          {:ok, %__MODULE__{outcome: outcome, gap: json["gap"]}}
        else
          {:error, "a rule cannot assert outcome #{inspect(outcome)} when it fires"}
        end

      :error ->
        {:error, "unknown outcome #{inspect(outcome)}"}
    end
  rescue
    ArgumentError -> {:error, "unknown outcome #{inspect(outcome)}"}
  end

  def from_json(_), do: {:error, "an outcome declaration must have an outcome"}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
