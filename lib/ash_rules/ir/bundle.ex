# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.Bundle do
  @moduledoc """
  An immutable, content-hashed snapshot of a rule set plus its fact schema.

  The bundle is what evaluators consume and what auditors sign: rules and schema
  revisions, the combining algorithm the rule set declared, a SHA-256 content
  hash over the canonical JSON of everything above, and the IR compiler version
  that produced it. Evaluation results pin the bundle hash, so a finding always
  names the exact rules that produced it.
  """

  alias AshRules.Ir.Fact
  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Rule

  defstruct [
    :rules,
    :fact_schema,
    :revision,
    :fact_schema_revision,
    :combining,
    :content_hash,
    :compiler_version
  ]

  @type t() :: %__MODULE__{
          rules: [Rule.t()],
          fact_schema: FactSchema.t(),
          revision: String.t(),
          fact_schema_revision: String.t(),
          combining: AshRules.Combining.algorithm(),
          content_hash: String.t() | nil,
          compiler_version: String.t()
        }

  @current_compiler_version "1"

  @doc """
  Builds a bundle and computes its content hash. Rules are stored sorted by id
  and the hash is over canonical JSON, so two bundles with the same content are
  byte-identical regardless of declaration order.

  Spark compiler metadata (`__spark_metadata__`) is stripped: the IR is pure
  data, and the metadata must not leak into hashes or wire forms.
  """
  @spec new([Rule.t()], FactSchema.t() | [AshRules.Ir.Fact.t()], keyword()) :: t()
  def new(rules, fact_schema, opts \\ []) do
    fact_schema = normalize_schema(fact_schema)
    rules = rules |> Enum.sort_by(& &1.id) |> Enum.map(&normalize_rule/1)

    bundle = %__MODULE__{
      rules: rules,
      fact_schema: fact_schema,
      revision: opts[:revision] || "1",
      fact_schema_revision: opts[:fact_schema_revision] || "1",
      combining: opts[:combining] || :deny_overrides,
      compiler_version: @current_compiler_version
    }

    %{bundle | content_hash: content_hash(bundle)}
  end

  @doc "The bundle's SHA-256 content hash over its canonical JSON."
  @spec content_hash(t()) :: String.t()
  def content_hash(%__MODULE__{} = bundle) do
    bundle
    |> to_json()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The canonical JSON object form, for the codec and the content hash."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = bundle) do
    %{
      "revision" => bundle.revision,
      "fact_schema_revision" => bundle.fact_schema_revision,
      "combining" => Atom.to_string(bundle.combining),
      "fact_schema" => FactSchema.to_json(bundle.fact_schema),
      "rules" => Enum.map(bundle.rules, &Rule.to_json/1)
    }
  end

  @doc """
  Decodes and validates a JSON-decoded bundle map on admission.

  Structural validation happens here (shapes, types, outcome domains);
  semantic validation — unknown predicates, type mismatches, unbound variables,
  missing outcome/severity/combining metadata — runs through the same verifiers
  the DSL uses. There is no `Code.eval` on this path and no persisted AST:
  tenant-authored rules enter as decoded data and pass the identical checks.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"rules" => rules, "fact_schema" => fact_schema} = json)
      when is_list(rules) and is_list(fact_schema) do
    with {:ok, schema} <- FactSchema.from_json(fact_schema),
         {:ok, rules} <- decode_rules(rules, fact_types(schema)) do
      bundle =
        new(rules, schema,
          revision: json["revision"] || "1",
          fact_schema_revision: json["fact_schema_revision"] || "1",
          combining: decode_combining(json["combining"])
        )

      case AshRules.Verifier.verify_bundle(bundle) do
        :ok -> {:ok, bundle}
        {:error, errors} -> {:error, errors}
      end
    end
  end

  def from_json(_), do: {:error, "a bundle must be an object with rules and fact_schema"}

  defp fact_types(%FactSchema{facts: facts}) do
    Map.new(facts, fn %Fact{name: name, type: type} -> {name, type} end)
  end

  defp decode_rules(rules, fact_types) do
    rules
    |> Enum.reduce_while({:ok, []}, fn json, {:ok, acc} ->
      case Rule.from_json(json, fact_types) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, error} -> {:halt, {:error, "rule: #{error}"}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_combining(combining) when is_binary(combining) do
    String.to_existing_atom(combining)
  rescue
    ArgumentError -> :deny_overrides
  end

  defp decode_combining(_), do: :deny_overrides

  defp normalize_schema(%FactSchema{} = schema),
    do: %{schema | facts: Enum.map(schema.facts, &normalize_fact/1)}

  defp normalize_schema(facts), do: FactSchema.new(Enum.map(facts, &normalize_fact/1))

  defp normalize_fact(%Fact{} = fact), do: drop_metadata(fact)

  defp normalize_rule(%Rule{} = rule) do
    %{
      rule
      | applicability: Enum.map(rule.applicability, &normalize_predicate/1),
        failure_conditions: Enum.map(rule.failure_conditions, &normalize_predicate/1),
        outcome: normalize_outcome(rule.outcome)
    }
  end

  defp normalize_predicate(%Predicate{} = predicate), do: drop_metadata(predicate)
  defp normalize_predicate(other), do: other

  defp normalize_outcome(%OutcomeDeclaration{} = outcome), do: drop_metadata(outcome)
  defp normalize_outcome(other), do: other

  defp drop_metadata(struct) do
    if Map.has_key?(struct, :__spark_metadata__) do
      %{struct | __spark_metadata__: nil}
    else
      struct
    end
  end
end
