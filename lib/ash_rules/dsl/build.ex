# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.Build do
  @moduledoc false

  # Entity transforms: compile DSL drafts into IR structs as the entities are
  # built, so the DSL state holds plain IR from that point on.

  alias AshRules.Dsl.PredicateRef
  alias AshRules.Dsl.RuleDraft
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Rule

  @spec rule(RuleDraft.t()) :: {:ok, Rule.t()} | {:error, String.t()}
  def rule(%RuleDraft{} = draft) do
    fields = merge_opts(draft)

    with {:ok, outcome} <- outcome(draft) do
      {:ok,
       Rule.new(
         id: fields[:id],
         name: draft.name,
         revision: fields[:revision] || "1",
         severity: fields[:severity],
         applicability: unwrap(draft.applicability),
         failure_conditions: unwrap(draft.failure_conditions),
         outcome: outcome,
         message: fields[:message],
         remediation_ref: fields[:remediation_ref],
         controls: fields[:controls] || [],
         evidence: fields[:evidence] || [],
         source: fields[:source]
       )}
    end
  end

  # The rule grammar is `rule "name", id: ..., severity: ... do ... end`.
  # Spark hands the trailing keyword list to the entity as the `opts` argument
  # (the do-block occupies the trailing param), so the rule fields actually
  # live in `draft.opts`.
  @rule_opts [
    :id,
    :revision,
    :severity,
    :message,
    :remediation_ref,
    :controls,
    :evidence,
    :source
  ]

  defp merge_opts(%RuleDraft{opts: opts}) when is_list(opts) do
    unknown = Keyword.keys(opts) -- @rule_opts

    if unknown == [] do
      Map.new(opts)
    else
      raise ArgumentError,
            "unknown rule option(s) #{inspect(unknown)}. " <>
              "Valid options: #{inspect(@rule_opts)}"
    end
  end

  defp outcome(%RuleDraft{outcomes: []}),
    do: {:ok, nil}

  defp outcome(%RuleDraft{outcomes: [outcome]}), do: {:ok, outcome}

  defp outcome(%RuleDraft{id: id, outcomes: [_ | _] = outcomes}) do
    {:error,
     "rule #{inspect(id)} declares #{length(outcomes)} outcomes. " <>
       "Declare one `outcome :noncompliant, gap: \"<control reference>\"` per rule"}
  end

  defp unwrap(predicate_refs) do
    Enum.map(predicate_refs, fn
      %PredicateRef{predicate: %Predicate{} = predicate} -> predicate
      %PredicateRef{} -> raise "predicate ref was never built"
    end)
  end
end
