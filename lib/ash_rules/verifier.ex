# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Verifier do
  @moduledoc """
  The semantic verifiers, shared by the DSL and the IR decoder.

  Compile-time validation before activation, never at evaluation — the Cedar
  pattern. Every check produces a message that names the failing rule and the
  fix, and the same checks run whether a rule set was authored in the DSL or
  arrived as decoded IR from a tenant control plane.

  Checks:

    * every predicate exists in the fact schema (unknown predicate)
    * predicate values type-check against the schema (type mismatch)
    * every variable is bound by an earlier `has` clause (unbound variable)
    * every rule declares a severity and an outcome (missing metadata)
    * every `:noncompliant` outcome carries a gap reference (combining
      metadata present at every level)
    * rule ids are unique
  """

  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Rule
  alias AshRules.Ir.Var

  @type error() :: String.t()

  @doc "Verifies a whole bundle. `:ok` or `{:error, [message]}` in rule order."
  @spec verify_bundle(AshRules.Ir.Bundle.t()) :: :ok | {:error, [error()]}
  def verify_bundle(%AshRules.Ir.Bundle{} = bundle) do
    verify(bundle.fact_schema, bundle.rules)
  end

  @doc "Verifies rules against a fact schema. `:ok` or `{:error, [message]}`."
  @spec verify(FactSchema.t(), [Rule.t()]) :: :ok | {:error, [error()]}
  def verify(%FactSchema{} = schema, rules) do
    errors =
      rules
      |> Enum.flat_map(&verify_rule(schema, &1))
      |> verify_unique_ids(rules)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Verifies one rule. Returns the list of refusal messages (empty if valid)."
  @spec verify_rule(FactSchema.t(), Rule.t()) :: [error()]
  def verify_rule(schema, %Rule{} = rule) do
    predicate_errors(schema, rule) ++
      metadata_errors(rule) ++
      variable_errors(rule) ++
      id_errors(rule)
  end

  # --- predicates -----------------------------------------------------------

  defp predicate_errors(schema, rule) do
    rule
    |> Rule.predicates()
    |> Enum.flat_map(&predicate_error(schema, rule, &1))
  end

  defp predicate_error(schema, rule, %Predicate{name: name} = predicate) do
    case FactSchema.fetch(schema, name) do
      :error ->
        [
          "rule #{inspect(rule.id)}: predicate #{inspect(name)} is not in the fact schema. " <>
            "Declare it in fact_schema with `fact #{inspect(name)}, :type`"
        ]

      {:ok, fact} ->
        value_errors(schema, rule, predicate, fact)
    end
  end

  defp value_errors(_schema, rule, %Predicate{value: v} = predicate, fact) do
    # Only the value position type-checks against the fact: the subject is an
    # entity key, not a fact value.
    value_errors =
      case deref_literal(v) do
        {:literal, literal} -> literal_error(rule, predicate, :value, fact, literal)
        :variable -> []
      end

    value_errors ++ one_of_errors(rule, predicate, fact, v)
  end

  defp deref_literal(%Var{}), do: :variable
  defp deref_literal(literal), do: {:literal, literal}

  defp literal_error(rule, _predicate, _position, fact, literal) do
    if AshRules.Ir.Fact.valid_literal?(fact, literal) do
      []
    else
      [
        "rule #{inspect(rule.id)}: predicate #{inspect(fact.name)} value " <>
          inspect(literal) <>
          " does not type-check against #{inspect(fact.type)}" <>
          one_of_hint(fact) <> ". Use a #{type_description(fact)} value"
      ]
    end
  end

  defp one_of_errors(rule, _predicate, %{type: :atom, one_of: one_of} = fact, value)
       when one_of != nil and not is_struct(value, Var) do
    if value in one_of do
      []
    else
      [
        "rule #{inspect(rule.id)}: predicate #{inspect(fact.name)} value #{inspect(value)} " <>
          "is outside one_of #{inspect(one_of)}. Use one of the declared values"
      ]
    end
  end

  defp one_of_errors(_rule, _predicate, _fact, _value), do: []

  defp one_of_hint(%{one_of: nil}), do: ""
  defp one_of_hint(%{one_of: one_of}), do: " (one_of: #{inspect(one_of)})"

  defp type_description(%{type: :atom, one_of: one_of}) when one_of != nil,
    do: "declared one_of"

  defp type_description(%{type: type}), do: Atom.to_string(type)

  # --- metadata -------------------------------------------------------------

  defp metadata_errors(%Rule{severity: nil} = rule) do
    [
      "rule #{inspect(rule.id)}: no severity declared. " <>
        "Add `severity: :low | :medium | :high | :critical` to the rule"
    ] ++ metadata_errors(%{rule | severity: :medium})
  end

  defp metadata_errors(%Rule{outcome: nil} = rule) do
    [
      "rule #{inspect(rule.id)}: no outcome declared. " <>
        "Add `outcome :noncompliant, gap: \"<control reference>\"` to the rule body"
    ]
  end

  defp metadata_errors(
         %Rule{outcome: %OutcomeDeclaration{outcome: :noncompliant, gap: nil}} = rule
       ) do
    [
      "rule #{inspect(rule.id)}: outcome :noncompliant has no gap. " <>
        "Combining metadata must be present at every level — " <>
        "add `gap: \"<control reference>\"` to the outcome"
    ]
  end

  defp metadata_errors(_rule), do: []

  # --- variables ------------------------------------------------------------

  defp variable_errors(rule) do
    {_, _, errors} =
      Rule.predicates(rule)
      |> Enum.reduce({rule.id, MapSet.new(), []}, fn predicate, {rule_id, bound, errors} ->
        {bound, errors} =
          track_positions(rule_id, predicate, [predicate.subject, predicate.value], bound, errors)

        {rule_id, bound, errors}
      end)

    Enum.uniq(errors)
  end

  # A `:has` clause binds its own variables (leftmost position first);
  # a `:neg` clause only reads — every variable in it must already be bound.
  defp track_positions(_rule_id, _predicate, [], bound, errors), do: {bound, errors}

  defp track_positions(rule_id, %{op: :has} = predicate, [%Var{} = var | rest], bound, errors) do
    track_positions(rule_id, predicate, rest, MapSet.put(bound, var.name), errors)
  end

  defp track_positions(rule_id, predicate, [%Var{name: name} | rest], bound, errors) do
    if MapSet.member?(bound, name) do
      track_positions(rule_id, predicate, rest, bound, errors)
    else
      error =
        "rule #{inspect(rule_id)}: variable #{inspect(name)} " <>
          "is used before it is bound. " <>
          "Bind it with an earlier has(...) clause in when_requires"

      track_positions(rule_id, predicate, rest, bound, errors ++ [error])
    end
  end

  defp track_positions(rule_id, predicate, [_literal | rest], bound, errors) do
    track_positions(rule_id, predicate, rest, bound, errors)
  end

  # --- ids ------------------------------------------------------------------

  defp id_errors(%Rule{id: id}) when is_binary(id) and byte_size(id) > 0, do: []

  defp id_errors(%Rule{id: id}) do
    ["rule #{inspect(id)}: id must be a non-empty string"]
  end

  defp verify_unique_ids(errors, rules) do
    duplicate_ids =
      rules
      |> Enum.map(& &1.id)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    Enum.map(duplicate_ids, fn id ->
      "rule #{inspect(id)}: id is declared more than once. Rule ids must be unique — " <>
        "they are the provenance key every finding is filed under"
    end) ++ errors
  end
end
