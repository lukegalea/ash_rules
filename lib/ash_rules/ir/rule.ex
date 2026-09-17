# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.Rule do
  @moduledoc """
  One rule of the serializable IR: applicability, failure conditions, the
  asserted outcome and the metadata an auditor needs.

  A rule reads:

  * If every predicate in `applicability` holds, the rule applies.
  * If, in addition, every predicate in `failure_conditions` holds, the rule
    fires and asserts its outcome declaration (almost always a finding:
    `:noncompliant` under a gap reference).
  * If it applies but the failure conditions do not all hold, it is
    `:compliant`.
  * If evaluation of any ground probe hits a fact whose schema semantics is
    `missing: :unknown`, the rule is `:unknown` — never compliant.
  * Otherwise it is `:not_applicable`.

  `severity`, the outcome declaration's `gap` (combining metadata),
  `controls`, `evidence`, `message` and `remediation_ref` are what turns a
  boolean answer into an auditable finding. The verifiers refuse rules missing
  the mandatory ones.
  """

  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate

  defstruct [
    :id,
    :name,
    :revision,
    :severity,
    :applicability,
    :failure_conditions,
    :outcome,
    :message,
    :remediation_ref,
    :controls,
    :evidence,
    :source
  ]

  @type severity() :: :low | :medium | :high | :critical

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          revision: String.t(),
          severity: severity() | nil,
          applicability: [Predicate.t()],
          failure_conditions: [Predicate.t()],
          outcome: OutcomeDeclaration.t() | nil,
          message: String.t() | nil,
          remediation_ref: String.t() | nil,
          controls: [String.t()],
          evidence: [String.t()],
          source: String.t() | nil
        }

  @severities [:low, :medium, :high, :critical]

  @doc "The severities a rule may declare."
  @spec severities() :: [severity(), ...]
  def severities, do: @severities

  @doc "Builds a rule struct; used by the DSL compiler and the codec."
  @spec new(keyword()) :: t()
  def new(fields) do
    struct!(
      __MODULE__,
      fields
      |> Keyword.put_new(:revision, "1")
      |> Keyword.update(:applicability, [], &List.wrap/1)
      |> Keyword.update(:failure_conditions, [], &List.wrap/1)
      |> Keyword.update(:controls, [], &List.wrap/1)
      |> Keyword.update(:evidence, [], &List.wrap/1)
    )
  end

  @doc "Every predicate of the rule, applicability first."
  @spec predicates(t()) :: [Predicate.t()]
  def predicates(%__MODULE__{applicability: app, failure_conditions: failures}) do
    app ++ failures
  end

  @doc "The JSON object form, for the codec and canonical hashing."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = rule) do
    %{
      "id" => rule.id,
      "name" => rule.name,
      "revision" => rule.revision,
      "applicability" => Enum.map(rule.applicability, &Predicate.to_json/1),
      "failure_conditions" => Enum.map(rule.failure_conditions, &Predicate.to_json/1),
      "controls" => rule.controls,
      "evidence" => rule.evidence
    }
    |> put_if("severity", rule.severity && Atom.to_string(rule.severity))
    |> put_if("outcome", rule.outcome && OutcomeDeclaration.to_json(rule.outcome))
    |> put_if("message", rule.message)
    |> put_if("remediation_ref", rule.remediation_ref)
    |> put_if("source", rule.source)
  end

  @doc "Decodes the JSON object form. `fact_types` maps predicate names to value types."
  @spec from_json(map(), %{optional(atom()) => atom()}) :: {:ok, t()} | {:error, String.t()}
  def from_json(json, fact_types \\ %{})

  def from_json(%{"id" => id, "name" => name} = json, fact_types)
      when is_binary(id) and is_binary(name) do
    with {:ok, severity} <- decode_severity(json["severity"]),
         {:ok, applicability} <- decode_predicates(json["applicability"] || [], fact_types),
         {:ok, failure_conditions} <-
           decode_predicates(json["failure_conditions"] || [], fact_types),
         {:ok, outcome} <- decode_outcome(json["outcome"]) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         revision: json["revision"] || "1",
         severity: severity,
         applicability: applicability,
         failure_conditions: failure_conditions,
         outcome: outcome,
         message: json["message"],
         remediation_ref: json["remediation_ref"],
         controls: json["controls"] || [],
         evidence: json["evidence"] || [],
         source: json["source"]
       }}
    end
  end

  def from_json(_json, _fact_types), do: {:error, "a rule must have id and name"}

  defp decode_severity(nil), do: {:ok, nil}

  defp decode_severity(severity) when is_binary(severity) do
    values = Enum.map(@severities, &Atom.to_string/1)

    if severity in values do
      {:ok, String.to_existing_atom(severity)}
    else
      {:error, "severity #{inspect(severity)} is not one of #{inspect(@severities)}"}
    end
  end

  defp decode_severity(severity),
    do: {:error, "severity must be a string, got #{inspect(severity)}"}

  defp decode_predicates(predicates, fact_types) when is_list(predicates) do
    predicates
    |> Enum.reduce_while({:ok, []}, fn json, {:ok, acc} ->
      case Predicate.from_json(json, fact_types) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, predicates} -> {:ok, Enum.reverse(predicates)}
      {:error, error} -> {:error, "predicate: #{error}"}
    end
  end

  defp decode_predicates(_predicates, _fact_types), do: {:error, "predicate lists must be lists"}

  defp decode_outcome(nil), do: {:ok, nil}

  defp decode_outcome(json) when is_map(json) do
    case OutcomeDeclaration.from_json(json) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, error} -> {:error, "outcome declaration: #{error}"}
    end
  end

  defp decode_outcome(_), do: {:error, "outcome declaration must be an object"}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
