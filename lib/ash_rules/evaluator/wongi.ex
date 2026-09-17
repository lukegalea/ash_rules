# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Wongi.Engine) do
  defmodule AshRules.Evaluator.Wongi do
    @moduledoc """
    The Wongi.Engine adapter: compiles the IR to a Rete network and reads
    results back through production tokens.

    Each IR rule compiles to two wongi rules — one over the applicability
    matchers (marking the rule applicable), one over applicability plus
    failure conditions (generating the finding). The distinction is what lets
    this adapter and `AshRules.Evaluator.Direct` agree on `:compliant` versus
    `:not_applicable`. Provenance comes from `Wongi.Engine.tokens/2` on the
    production refs, translated back to domain rule ids — engine refs never
    leave this module.

    Missing-data semantics are resolved *before* compilation, through the same
    `AshRules.Facts` helpers the direct evaluator uses: a rule whose ground
    probe hits an absent `missing: :unknown` fact never enters the network
    (it is `:unknown`), and absent `:false`-semantics probes are asserted as
    their synthesized triple so the network sees exactly what the direct
    evaluator sees. Parity is a contract and the suite enforces it.

    Generated facts are retracted automatically when their support disappears
    — retract a premise and the finding goes with it (asserted by the truth
    maintenance test).

    This module is only compiled when the optional `wongi_engine` dependency
    is loadable; otherwise a stub returns `{:error, :wongi_not_available}`.
    """

    @behaviour AshRules.Evaluator

    alias AshRules.Evaluator.Direct
    alias AshRules.Evaluator.Ordering
    alias AshRules.Facts
    alias AshRules.Ir.Bundle
    alias AshRules.Ir.FactSchema
    alias AshRules.Ir.Predicate
    alias AshRules.Ir.Rule
    alias AshRules.Ir.Var
    alias AshRules.Result
    alias AshRules.Result.Requirement

    @finding_predicate :finding
    @applicable_predicate :applicable

    @impl AshRules.Evaluator
    def evaluate(%Bundle{} = bundle, facts, opts) do
      with {:ok,
            %{
              engine: engine,
              failure_refs: failure_refs,
              applicability_refs: applicability_refs,
              unknown: unknown
            }} <-
             engine(bundle, facts) do
        requirements =
          Enum.map(bundle.rules, fn rule ->
            case Map.get(unknown, rule.id) do
              {:unknown, missing} ->
                requirement(rule, :unknown, [], missing)

              nil ->
                evaluate_compiled(rule, engine, applicability_refs, failure_refs)
            end
          end)

        {:ok, Result.new(bundle, requirements, __MODULE__, Keyword.take(opts, [:seed]))}
      end
    end

    @doc """
    Builds a live engine for a bundle: rules compiled, facts asserted, the
    ref of each compiled rule kept under its domain rule id. Used by
    `evaluate/3` and available for hosts that want interactive truth
    maintenance.
    """
    @spec engine(Bundle.t(), Facts.t() | [Facts.triple()]) ::
            {:ok,
             %{
               engine: Wongi.Engine.t(),
               failure_refs: %{String.t() => reference()},
               applicability_refs: %{String.t() => reference()},
               unknown: %{String.t() => {:unknown, Facts.triple()}}
             }}
            | {:error, term()}
    def engine(%Bundle{} = bundle, facts) do
      with {:ok, memory} <- Facts.prepare(bundle.fact_schema, facts) do
        {unknown, compiled} =
          bundle.rules
          |> Enum.split_with(&(!is_nil(Direct.reachable_unknown_probe(&1, memory))))
          |> then(fn {unknown_rules, compiled_rules} ->
            {Map.new(
               unknown_rules,
               &{&1.id, {:unknown, Direct.reachable_unknown_probe(&1, memory)}}
             ), Enum.map(compiled_rules, &compile_rule(&1, memory))}
          end)

        engine = assert_all(memory, compiled)
        {engine, refs} = install_all(engine, compiled)

        {:ok,
         %{
           engine: engine,
           failure_refs: Map.new(refs, fn {id, {_applicable, failure}} -> {id, failure} end),
           applicability_refs:
             Map.new(refs, fn {id, {applicable, _failure}} -> {id, applicable} end),
           unknown: unknown
         }}
      end
    end

    # --- compilation ----------------------------------------------------------

    defp compile_rule(rule, memory) do
      applicable_matchers = matchers(rule.applicability)
      failure_matchers = matchers(rule.applicability ++ rule.failure_conditions)

      applicable_rule =
        Wongi.Engine.DSL.rule(rule.id,
          forall: applicable_matchers,
          do: [Wongi.Engine.DSL.gen(rule.id, @applicable_predicate, :yes)]
        )

      failure_rule =
        Wongi.Engine.DSL.rule(rule.id,
          forall: failure_matchers,
          do: [Wongi.Engine.DSL.gen(rule.id, @finding_predicate, :triggered)]
        )

      {rule.id, applicable_rule, failure_rule, synthesized(rule, memory)}
    end

    defp matchers(predicates) do
      Enum.map(predicates, fn
        %Predicate{op: :has, subject: s, name: name, value: v} ->
          Wongi.Engine.DSL.has(term(s), name, term(v))

        %Predicate{op: :neg, subject: s, name: name, value: v} ->
          Wongi.Engine.DSL.neg(term(s), name, term(v))
      end)
    end

    defp term(%Var{name: name}), do: Wongi.Engine.DSL.var(name)
    defp term(value), do: value

    # Absent `:false`/`:no_fact` ground probes with value `false` are
    # asserted so the network sees the synthesized triple.
    defp synthesized(rule, memory) do
      rule
      |> Rule.predicates()
      |> Enum.filter(&Predicate.ground?/1)
      |> Enum.flat_map(fn predicate ->
        triple = {predicate.subject, predicate.name, predicate.value}

        absent_and_synthesized?(memory, predicate, triple)
      end)
    end

    defp absent_and_synthesized?(memory, predicate, triple) do
      entry = schema_entry(memory, predicate)

      if Facts.member?(memory, triple) or
           Facts.any_fact?(memory, elem(triple, 0), predicate.name) do
        []
      else
        case Facts.absence(entry, triple) do
          {:absent, :as_false} -> [{elem(triple, 0), elem(triple, 1), false}]
          _absent -> []
        end
      end
    end

    # --- engine assembly ------------------------------------------------------

    defp assert_all(memory, compiled) do
      synthesized =
        compiled
        |> Enum.flat_map(fn {_id, _app, _fail, synthesized} -> synthesized end)
        |> Enum.uniq()
        |> Enum.sort()

      engine = Enum.reduce(synthesized, Wongi.Engine.new(), &Wongi.Engine.assert(&2, &1))

      memory.triples
      |> Enum.sort()
      |> Enum.reduce(engine, &Wongi.Engine.assert(&2, &1))
    end

    defp install_all(engine, compiled) do
      Enum.map_reduce(compiled, engine, fn {id, applicable_rule, failure_rule, _synthesized},
                                           engine ->
        {engine, applicable_ref} = Wongi.Engine.compile_and_get_ref(engine, applicable_rule)
        {engine, failure_ref} = Wongi.Engine.compile_and_get_ref(engine, failure_rule)
        {{id, {applicable_ref, failure_ref}}, engine}
      end)
      |> then(fn {refs, engine} -> {engine, refs} end)
    end

    # --- reading results ------------------------------------------------------

    defp evaluate_compiled(rule, engine, applicability_refs, failure_refs) do
      failure_tokens = tokens(engine, Map.fetch!(failure_refs, rule.id))

      case failure_tokens do
        [] ->
          applicability_tokens = tokens(engine, Map.fetch!(applicability_refs, rule.id))

          case applicability_tokens do
            [] -> requirement(rule, :not_applicable, [], [])
            _applicable -> requirement(rule, :compliant, [], [])
          end

        tokens ->
          bindings = Ordering.sort_bindings(Enum.map(tokens, &Wongi.Engine.Token.assignments/1))
          consumed = Enum.flat_map(tokens, &consumed_facts/1) |> Enum.uniq() |> Enum.sort()
          requirement = requirement(rule, rule.outcome.outcome, bindings, consumed)
          %{requirement | message: render_message(rule, bindings)}
      end
    end

    defp tokens(engine, ref) do
      engine |> Wongi.Engine.tokens(ref) |> Enum.to_list()
    end

    # Provenance: every WME the token (or its ancestors) matched, excluding
    # this adapter's own productions.
    defp consumed_facts(token) do
      token
      |> walk_wmes(MapSet.new())
      |> MapSet.to_list()
      |> Enum.reject(fn {_s, predicate, _o} ->
        predicate in [@finding_predicate, @applicable_predicate]
      end)
    end

    defp walk_wmes(token, acc) do
      acc = if token.wme, do: MapSet.put(acc, wme_triple(token.wme)), else: acc
      Enum.reduce(token.parents, acc, &walk_wmes/2)
    end

    defp wme_triple(wme), do: {wme.subject, wme.predicate, wme.object}

    # --- shared requirement assembly -------------------------------------------

    # On the unknown path both evaluators keep only the missing facts: an
    # undecidable rule's provenance *is* the data gap, and parity holds.
    defp requirement(rule, :unknown, _bindings, missing_probe) do
      %Requirement{
        rule_id: rule.id,
        rule_revision: rule.revision,
        severity: rule.severity,
        gap: gap(rule),
        outcome: :unknown,
        message: nil,
        bindings: [],
        consumed_facts: [],
        probed_facts: [],
        missing_facts: [missing_probe]
      }
    end

    defp requirement(rule, outcome, bindings, consumed) do
      %Requirement{
        rule_id: rule.id,
        rule_revision: rule.revision,
        severity: rule.severity,
        gap: gap(rule),
        outcome: outcome,
        message: nil,
        bindings: bindings,
        consumed_facts: consumed,
        probed_facts: [],
        missing_facts: []
      }
    end

    defp gap(%Rule{outcome: %AshRules.Ir.OutcomeDeclaration{} = declaration}), do: declaration.gap
    defp gap(_rule), do: nil

    defp schema_entry(memory, predicate) do
      case FactSchema.fetch(memory.schema, predicate.name) do
        {:ok, fact} -> fact
        :error -> :not_declared
      end
    end

    defp render_message(rule, bindings) do
      message = rule.message || rule.name

      Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
        render_placeholder(bindings, key)
      end)
    end

    defp render_placeholder([], key), do: "%{#{key}}"

    defp render_placeholder(bindings, key) do
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
else
  defmodule AshRules.Evaluator.Wongi do
    @moduledoc """
    The Wongi.Engine adapter stub.

    This module is compiled when the optional `wongi_engine` dependency is
    **not** loadable. Every call returns `{:error, :wongi_not_available}`;
    `AshRules.Evaluator.Direct` is the default evaluator and needs nothing
    from here.
    """

    @behaviour AshRules.Evaluator

    @impl AshRules.Evaluator
    def evaluate(_bundle, _facts, _opts), do: {:error, :wongi_not_available}
  end
end
