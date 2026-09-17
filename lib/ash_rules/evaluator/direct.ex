# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator.Direct do
  @moduledoc """
  The default evaluator: pure Elixir matching over the IR predicates.

  A rule evaluates as:

    * `applicability` (`when_requires`) must all hold — otherwise
      `:not_applicable`;
    * `failure_conditions` (`fails_when`) must all hold — otherwise
      `:compliant`;
    * if they all hold, the rule fires and asserts its outcome declaration,
      one finding per complete variable binding.

  Matching is a conjunction of triple probes over the working memory with
  variable binding: a `%AshRules.Ir.Var{}` binds on its first `:has` match and
  unifies thereafter. `:neg` clauses never bind — the verifiers guarantee their
  variables are already bound, so their probes are ground.

  Absence is three-valued, resolved through `AshRules.Facts.absence/2`: a
  ground probe on an absent fact with `missing: :unknown` semantics makes the
  rule `:unknown`; with `:false`/`:no_fact` semantics the value behaves as
  `false`. `:unknown` dominates any branch it touches, so an unknowable
  failure condition never yields `:compliant`. A probe with an unbound
  variable position simply finds whatever binds — absence of a *variable*
  probe is not a data gap, because no specific fact is missing.

  Determinism is structural, not seeded: rules evaluate in id order, candidate
  facts in sorted order, findings are indexed over a sorted, de-duplicated
  binding list. Repeated evaluation of the same inputs is byte-identical
  (asserted by the suite at n=50).
  """

  @behaviour AshRules.Evaluator

  alias AshRules.Evaluator.Ordering
  alias AshRules.Facts
  alias AshRules.Ir.Bundle
  alias AshRules.Ir.Fact
  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.OutcomeDeclaration
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Rule
  alias AshRules.Ir.Var
  alias AshRules.Result
  alias AshRules.Result.Requirement

  # Provenance accumulator: consumed facts (matches, including synthesized
  # absences-as-false), probed facts (ground triples checked against absence),
  # and missing facts (absences the schema says must be surfaced).
  defmodule Acc do
    @moduledoc false

    defstruct consumed: MapSet.new(), probed: MapSet.new(), missing: MapSet.new()

    @spec add(%__MODULE__{}, consumed: [Facts.triple()], probed: [Facts.triple()]) ::
            %__MODULE__{}
    def add(acc, consumed: consumed, probed: probed) do
      %__MODULE__{
        consumed: Enum.reduce(consumed, acc.consumed, &MapSet.put(&2, &1)),
        probed: Enum.reduce(probed, acc.probed, &MapSet.put(&2, &1)),
        missing: acc.missing
      }
    end

    @spec miss(%__MODULE__{}, Facts.triple()) :: %__MODULE__{}
    def miss(acc, probe) do
      %__MODULE__{
        consumed: acc.consumed,
        probed: MapSet.put(acc.probed, probe),
        missing: MapSet.put(acc.missing, probe)
      }
    end
  end

  @impl AshRules.Evaluator
  def evaluate(%Bundle{} = bundle, facts, opts) do
    with {:ok, memory} <- Facts.prepare(bundle.fact_schema, facts) do
      requirements = Enum.map(bundle.rules, &evaluate_rule(&1, memory))
      {:ok, Result.new(bundle, requirements, __MODULE__, Keyword.take(opts, [:seed]))}
    end
  end

  # --- one rule -------------------------------------------------------------

  defp evaluate_rule(rule, memory) do
    case run_rule(rule, memory) do
      {:fired, bindings, acc} -> fired(rule, bindings, acc)
      {:unknown, _bindings, acc} -> unknown(rule, acc)
      {:compliant, _bindings, acc} -> requirement(rule, :compliant, acc)
      {:not_applicable, _bindings, acc} -> requirement(rule, :not_applicable, acc)
    end
  end

  @doc """
  The first missing probe the rule's evaluation reaches, if any.

  This is the shared missing-data question both evaluators must answer
  identically: the Wongi adapter withholds exactly these rules from the
  network (as `:unknown`), because absence semantics — not the engine — decide
  what a missing fact means. Short-circuiting is honoured: a probe that is
  never reached (an earlier applicability clause already failed) does not make
  the rule unknown.
  """
  @spec reachable_unknown_probe(Rule.t(), Facts.t()) :: Facts.triple() | nil
  def reachable_unknown_probe(%Rule{} = rule, %Facts{} = memory) do
    case run_rule(rule, memory) do
      {:unknown, _bindings, acc} ->
        acc.missing |> MapSet.to_list() |> Enum.sort() |> List.first()

      _status ->
        nil
    end
  end

  # Binding states carry their own lineage: {bindings, consumed, probed}.
  # A fired rule reports provenance from its surviving bindings only — facts
  # read by branches that later died are not part of the finding's
  # justification. Compliant and not-applicable rules report everything the
  # evaluation read (the global accumulator), because the dead branches *are*
  # the justification for the absence of a finding.
  defp run_rule(rule, memory) do
    acc = %Acc{}
    start = [{%{}, [], []}]

    case conjunction(rule.applicability, start, memory, acc) do
      {:ok, bindings, acc} ->
        case conjunction(rule.failure_conditions, bindings, memory, acc) do
          {:ok, fired_bindings, acc} -> {:fired, fired_bindings, acc}
          {:unknown, acc} -> {:unknown, [], acc}
          {:no_match, acc} -> {:compliant, [], acc}
        end

      {:unknown, acc} ->
        {:unknown, [], acc}

      {:no_match, acc} ->
        {:not_applicable, [], acc}
    end
  end

  # On the unknown path only the missing facts survive: an undecidable rule's
  # provenance *is* the data gap, and the Wongi adapter — which withholds
  # unknown rules from the network entirely — produces the identical
  # requirement this way.
  defp unknown(rule, acc) do
    requirement(rule, :unknown, %Acc{missing: acc.missing})
  end

  defp fired(rule, fired_bindings, acc) do
    bindings =
      fired_bindings
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Ordering.sort_bindings()

    consumed =
      fired_bindings
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()

    probed =
      fired_bindings
      |> Enum.flat_map(&elem(&1, 2))
      |> Enum.uniq()
      |> Enum.sort()

    acc = %Acc{consumed: MapSet.new(consumed), probed: MapSet.new(probed), missing: acc.missing}
    requirement = requirement(rule, rule.outcome.outcome, acc, bindings)
    %{requirement | message: render_message(rule, bindings)}
  end

  # --- one conjunction ------------------------------------------------------

  # Each clause evaluates per binding state; unknown anywhere dominates and an
  # empty survivor set kills the conjunction.
  defp conjunction([], binding_states, _memory, acc), do: {:ok, binding_states, acc}

  defp conjunction([predicate | rest], binding_states, memory, acc) do
    case eval_clause(predicate, binding_states, memory, acc) do
      {:ok, binding_states, acc} -> conjunction(rest, binding_states, memory, acc)
      {:unknown, acc} -> {:unknown, acc}
      {:no_match, acc} -> {:no_match, acc}
    end
  end

  defp eval_clause(predicate, binding_states, memory, acc) do
    {results, acc} =
      Enum.flat_map_reduce(binding_states, acc, fn state, acc ->
        case probe(predicate, state, memory, acc) do
          {:match, new_states, acc} -> {[{:match, new_states}], acc}
          {:unknown, acc} -> {[{:unknown}], acc}
          {:no_match, acc} -> {[], acc}
        end
      end)

    survivors =
      results
      |> Enum.flat_map(fn
        {:match, new_states} -> new_states
        _other -> []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    cond do
      Enum.any?(results, &match?({:unknown}, &1)) ->
        {:unknown, acc}

      survivors == [] ->
        {:no_match, acc}

      true ->
        {:ok, survivors, acc}
    end
  end

  # --- one clause against one binding state ----------------------------------

  defp probe(%Predicate{op: :has} = predicate, {map, consumed, probed} = _state, memory, acc) do
    entry = entry(memory, predicate)
    subject = deref(predicate.subject, map)
    value = deref(predicate.value, map)

    cond do
      ground?(subject) and ground?(value) ->
        ground_has(
          {elem(subject, 1), predicate.name, elem(value, 1)},
          entry,
          {map, consumed, probed},
          memory,
          acc
        )

      subject == :unbound ->
        # Subject variable: candidates are the predicate's facts, unified
        # against whatever the value position resolves to.
        matches =
          memory
          |> Facts.with_predicate(predicate.name)
          |> Enum.flat_map(fn {candidate_subject, _name, candidate_value} = candidate ->
            with {:ok, map} <- unify(predicate.subject, subject, candidate_subject, map),
                 {:ok, map} <- unify(predicate.value, value, candidate_value, map) do
              [{map, consumed ++ [candidate], probed}]
            else
              _error -> []
            end
          end)

        verdict(matches, acc)

      true ->
        # Value variable, subject ground.
        {:bound, subject_value} = subject

        matches =
          memory
          |> Facts.with_predicate(predicate.name)
          |> Enum.flat_map(fn {candidate_subject, _name, candidate_value} = candidate ->
            with true <- AshRules.Ir.values_equal?(candidate_subject, subject_value),
                 {:ok, map} <- unify(predicate.value, value, candidate_value, map) do
              [{map, consumed ++ [candidate], probed}]
            else
              false -> []
              _error -> []
            end
          end)

        verdict(matches, acc)
    end
  end

  defp probe(%Predicate{op: :neg} = predicate, {map, consumed, probed} = _state, memory, acc) do
    # Variables in :neg are guaranteed bound by the verifiers; an unbound one
    # here is an invariant violation and fails loudly.
    {:bound, subject} = deref(predicate.subject, map)
    {:bound, value} = deref(predicate.value, map)
    triple = {subject, predicate.name, value}
    entry = entry(memory, predicate)

    cond do
      # The exact fact exists: neg fails (probed — we checked its absence).
      Facts.member?(memory, triple) ->
        {:no_match, Acc.add(acc, consumed: [], probed: [triple])}

      # The predicate has data with a different value: neg passes.
      Facts.any_fact?(memory, subject, predicate.name) ->
        {:match, [{map, consumed, probed ++ [triple]}],
         Acc.add(acc, consumed: [], probed: [triple])}

      true ->
        case Facts.absence(entry, triple) do
          {:absent, :unknown} ->
            acc = if Facts.reports_absence?(entry), do: Acc.miss(acc, triple), else: acc
            {:unknown, acc}

          {:absent, :as_false} ->
            # The synthesized false triple "exists", so neg fails.
            {:no_match, Acc.add(acc, consumed: [], probed: [triple])}

          {:absent, :mismatch} ->
            {:match, [{map, consumed, probed ++ [triple]}],
             Acc.add(acc, consumed: [], probed: [triple])}
        end
    end
  end

  defp ground_has(triple, entry, state, memory, acc) do
    {subject, name, _value} = triple
    {map, consumed, probed} = state

    cond do
      Facts.member?(memory, triple) ->
        {:match, [{map, consumed ++ [triple], probed}],
         Acc.add(acc, consumed: [triple], probed: [])}

      # The predicate has data, just not this value: a real mismatch.
      Facts.any_fact?(memory, subject, name) ->
        {:no_match, Acc.add(acc, consumed: [], probed: [triple])}

      true ->
        case Facts.absence(entry, triple) do
          {:absent, :unknown} ->
            acc = if Facts.reports_absence?(entry), do: Acc.miss(acc, triple), else: acc
            {:unknown, acc}

          {:absent, :as_false} ->
            acc = Acc.add(acc, consumed: [synthesized(triple)], probed: [triple])
            acc = if Facts.reports_absence?(entry), do: Acc.miss(acc, triple), else: acc
            {:match, [{map, consumed ++ [synthesized(triple)], probed ++ [triple]}], acc}

          {:absent, :mismatch} ->
            {:no_match, Acc.add(acc, consumed: [], probed: [triple])}
        end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp verdict([], acc), do: {:no_match, acc}

  # Matches are binding states from the variable probes; each consumed its own
  # candidate fact.
  defp verdict(matches, acc) do
    {:match, Enum.uniq_by(matches, &elem(&1, 0)), acc}
  end

  defp deref(%Var{name: name}, binding) do
    case Map.fetch(binding, name) do
      {:ok, value} -> {:bound, value}
      :error -> :unbound
    end
  end

  defp deref(term, _binding), do: {:bound, term}

  defp ground?({:bound, _value}), do: true
  defp ground?(:unbound), do: false

  defp unify(_pattern, {:bound, value}, candidate, binding) do
    if AshRules.Ir.values_equal?(value, candidate), do: {:ok, binding}, else: :error
  end

  defp unify(%Var{name: name}, :unbound, candidate, binding) do
    {:ok, Map.put(binding, name, candidate)}
  end

  @spec entry(map(), Predicate.t()) :: Fact.t()
  defp entry(memory, predicate) do
    case FactSchema.fetch(memory.schema, predicate.name) do
      {:ok, fact} ->
        fact

      :error ->
        # Verified bundles only contain declared predicates; this is an
        # invariant violation, not an evaluation outcome.
        raise ArgumentError,
              "predicate #{inspect(predicate.name)} is not in the fact schema"
    end
  end

  defp synthesized({subject, name, _value}), do: {subject, name, false}

  defp requirement(rule, outcome, acc, bindings \\ []) do
    %Requirement{
      rule_id: rule.id,
      rule_revision: rule.revision,
      severity: rule.severity,
      gap: gap(rule),
      outcome: outcome,
      message: nil,
      bindings: bindings,
      consumed_facts: Enum.sort(MapSet.to_list(acc.consumed)),
      probed_facts: Enum.sort(MapSet.to_list(acc.probed)),
      missing_facts: Enum.sort(MapSet.to_list(acc.missing))
    }
  end

  defp gap(%Rule{outcome: %OutcomeDeclaration{} = declaration}), do: declaration.gap
  defp gap(_rule), do: nil

  defp render_message(rule, bindings) do
    message = rule.message || rule.name

    Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
      render_placeholder(bindings, key)
    end)
  end

  defp render_placeholder([], key), do: "%{#{key}}"

  defp render_placeholder(bindings, key) do
    # Binding keys are IR variable names, which exist as atoms by the time a
    # binding exists; an unknown placeholder is left in place, never turned
    # into a new atom.
    case String.to_existing_atom(key) do
      atom when is_atom(atom) and atom != nil ->
        if Enum.any?(bindings, &Map.has_key?(&1, atom)) do
          bindings
          |> Enum.map(&Map.fetch!(&1, atom))
          |> Enum.uniq()
          |> Enum.map_join(", ", &render_value/1)
        else
          "%{#{key}}"
        end

      _other ->
        "%{#{key}}"
    end
  rescue
    ArgumentError -> "%{#{key}}"
  end

  defp render_value(value) when is_binary(value), do: value

  defp render_value(value) when is_atom(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp render_value(value), do: inspect(value)
end
