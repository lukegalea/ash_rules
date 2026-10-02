# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator.Set do
  @moduledoc """
  The set evaluator: compiles IR predicates into Ash queries over facts and
  partitions a set of subjects three ways — `in`, `out`, `unknown`.

  ADR 0048 ("a judgment is a predicate over any set"): filters, search,
  segments and bulk selection are the same declared predicates that rules
  evaluate per subject, evaluated over a set instead. Membership is
  three-valued and stays three-valued:

  | Partition | Meaning |
  |---|---|
  | `in` | an admitted fact says the predicate holds for the subject |
  | `out` | an admitted fact says it does not (or absence resolves to no) |
  | `unknown` | no fact decides it: absent data under `missing: :unknown` |

  `unknown` is surfaced as its own partition and never folded into either
  side. Negation is over admitted facts only: `neg` puts a subject in `out`
  when the probed fact exists — never "everything else".

  Only admitted facts are read — the working memory or the host's fact
  table, never observations (S1-24 §7.4: the set evaluator reads the fact
  table only; scores may order, facts decide). Absence semantics come from
  the same fact schema the direct evaluator honours: an absent probe on a
  `missing: :unknown` predicate lands in `unknown`; on `missing: :false` /
  `:no_fact` it resolves as `false` would (`has(…, false)` synthesizes a
  match, exactly like `AshRules.Facts.absence/2`).

  ## Equality is the IR's strict equality

  Fact values match with `AshRules.Ir.values_equal?/2` (`===`, no numeric
  coercion): a rule that says `80` does not match a fact that says `80.0`,
  and neither does a set query. The compiled Ash query narrows with the
  data layer's own equality (indexable, pushdownable — a superset that
  numeric coercion can only widen); the evaluator then verifies each
  candidate row strictly, so membership is exactly the direct evaluator's
  match semantics. The equivalence property test pins this.

  ## Sources

  `membership/3` runs over either:

    * in-memory facts — raw `{subject, predicate, value}` triples or a
      prepared `AshRules.Facts` struct (validated against the fact schema,
      like every evaluator); or
    * a fact resource — an Ash resource module whose records are already
      persisted facts, exposing the attributes `subject`, `predicate`
      (the string spelling of the IR predicate name) and `value`. The
      compiled queries run through `Ash.read/2`; pass `opts` through
      (`:actor`, `:tenant`, `:authorize?`) and policies apply as for any
      read. The universe is the subjects present in the source: subjects
      with no facts at all cannot be enumerated from a fact table and are
      the host's join (S1-24 §7.4).

  ## v0 shape of a set expression

  A set is a conjunction of IR predicates (`AshRules.Ir.Predicate`) over
  one subject: all subjects of a designated variable (`var(:account)`), or
  all probes about one ground subject. Probes about *other* ground subjects
  are context conditions — the same answer for every member of the set.
  Refused: two distinct variables, variables in a value position (join
  outputs, not subject sets), and ground-only conjunctions probing more
  than one subject. Compile-time, like every IR refusal, with the fix named.
  """

  alias AshRules.Facts
  alias AshRules.Ir
  alias AshRules.Ir.Bundle
  alias AshRules.Ir.Fact
  alias AshRules.Ir.FactSchema
  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var

  require Ash.Query

  defmodule Membership do
    @moduledoc """
    The three-valued partition a set evaluation returns.

    Each field is the sorted list of subjects in that partition; the three
    are disjoint and, for the subjects present in the fact source, their
    union is the whole set (asserted by the equivalence property test).
    """

    defstruct [:in, :out, :unknown]

    @type t() :: %__MODULE__{
            in: [term()],
            out: [term()],
            unknown: [term()]
          }
  end

  defmodule Probe do
    @moduledoc false

    defstruct [:op, :name, :value, :missing, :scope]

    @type t() :: %__MODULE__{
            op: :has | :neg,
            name: atom(),
            value: term(),
            missing: false | :unknown | :no_fact,
            scope: :designated | {:context, term()}
          }
  end

  defstruct [:schema, :subject, :probes]

  @type subject_key() :: {:var, atom()} | {:ground, term()}

  @type t() :: %__MODULE__{
          schema: FactSchema.t(),
          subject: subject_key(),
          probes: [Probe.t()]
        }

  @type source() :: Facts.t() | [Facts.triple()] | module()

  @type partition() :: %{in: MapSet.t(term()), out: MapSet.t(term()), unknown: MapSet.t(term())}

  @resource_attributes [:subject, :predicate, :value]

  # --- compilation: IR predicates -> set plan ---------------------------------

  @doc """
  Compiles a conjunction of IR predicates against a fact schema (or a bundle)
  into a set plan.

  Refusals are compile-time, naming the fix: an unknown predicate, two
  distinct subject variables, a variable in a value position, a ground-only
  conjunction probing more than one subject, or an empty conjunction.
  """
  @spec compile(FactSchema.t() | Bundle.t(), [Predicate.t()]) ::
          {:ok, t()} | {:error, String.t()}
  def compile(%Bundle{fact_schema: schema}, predicates), do: compile(schema, predicates)

  def compile(%FactSchema{} = schema, predicates) do
    with :ok <- validate_predicates(predicates),
         {:ok, subject} <- designate_subject(predicates),
         {:ok, probes} <- compile_probes(schema, predicates) do
      {:ok, %__MODULE__{schema: schema, subject: subject, probes: probes}}
    end
  end

  def compile(_schema, _predicates),
    do: {:error, "compile expects a fact schema or bundle and a list of IR predicates"}

  defp validate_predicates([]), do: {:error, "a set needs at least one predicate"}

  defp validate_predicates(predicates) do
    if Enum.all?(predicates, &match?(%Predicate{}, &1)) do
      :ok
    else
      {:error, "a set is a conjunction of %AshRules.Ir.Predicate{} structs"}
    end
  end

  defp designate_subject(predicates) do
    vars =
      predicates
      |> Enum.flat_map(&predicate_subject_vars/1)
      |> Enum.uniq()

    ground_subjects =
      predicates
      |> Enum.flat_map(&predicate_ground_subjects/1)
      |> Enum.uniq()

    cond do
      match?([_], vars) ->
        {:ok, {:var, hd(vars)}}

      vars == [] and match?([_], ground_subjects) ->
        {:ok, {:ground, hd(ground_subjects)}}

      vars == [] ->
        {:error,
         "a ground-only set must probe exactly one subject, got " <>
           inspect(ground_subjects) <> " — designate one subject variable, or one subject"}

      true ->
        {:error,
         "a set ranges over one subject variable, got several: #{inspect(vars)} — " <>
           "join outputs are not subject sets"}
    end
  end

  defp predicate_subject_vars(%Predicate{subject: %Var{name: name}}), do: [name]
  defp predicate_subject_vars(%Predicate{subject: _}), do: []

  defp predicate_ground_subjects(%Predicate{subject: %Var{}}), do: []
  defp predicate_ground_subjects(%Predicate{subject: subject}), do: [subject]

  defp compile_probes(schema, predicates) do
    Enum.reduce_while(predicates, {:ok, []}, fn predicate, {:ok, acc} ->
      case compile_probe(schema, predicate) do
        {:ok, probe} -> {:cont, {:ok, [probe | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, probes} -> {:ok, Enum.reverse(probes)}
      {:error, error} -> {:error, error}
    end
  end

  defp compile_probe(schema, %Predicate{op: op, subject: subject, name: name, value: value}) do
    with {:ok, fact} <- fetch_fact(schema, name),
         :ok <- reject_value_vars(value, name),
         :ok <- validate_literal(fact, name, value) do
      scope =
        case subject do
          %Var{} -> :designated
          ground -> {:context, ground}
        end

      {:ok, %Probe{op: op, name: name, value: value, missing: fact.missing, scope: scope}}
    end
  end

  # The same check the verifiers apply to rule predicates: a set probe's
  # value must type-check against the fact schema before anything queries.
  defp validate_literal(fact, name, value) do
    if Fact.valid_literal?(fact, value) do
      :ok
    else
      {:error,
       "predicate #{inspect(name)}: value #{inspect(value)} does not type-check against " <>
         inspect(fact.type) <> one_of_hint(fact)}
    end
  end

  defp one_of_hint(%{one_of: nil}), do: ""
  defp one_of_hint(%{one_of: one_of}), do: " (one_of: #{inspect(one_of)})"

  defp fetch_fact(schema, name) do
    case FactSchema.fetch(schema, name) do
      {:ok, fact} ->
        {:ok, fact}

      :error ->
        {:error,
         "predicate #{inspect(name)} is not in the fact schema. " <>
           "Declare it with `fact #{inspect(name)}, :type` in fact_schema, or drop the probe"}
    end
  end

  defp reject_value_vars(%Var{name: name}, probe_name) do
    {:error,
     "predicate #{inspect(probe_name)} has a variable (#{inspect(name)}) in its value " <>
       "position: set membership is over subjects, so values must be ground"}
  end

  defp reject_value_vars(_value, _name), do: :ok

  # --- evaluation -------------------------------------------------------------

  @doc """
  Compiles and evaluates in one step: `membership(schema_or_bundle, predicates, facts, opts)`.
  """
  @spec membership(FactSchema.t() | Bundle.t(), [Predicate.t()], source(), keyword()) ::
          {:ok, Membership.t()} | {:error, term()}
  def membership(schema_or_bundle, predicates, facts, opts) do
    with {:ok, plan} <- compile(schema_or_bundle, predicates) do
      membership(plan, facts, opts)
    end
  end

  @doc """
  Evaluates a set plan over facts and returns the three-valued partition.

  `facts` may be raw triples (validated against the plan's fact schema), a
  prepared `AshRules.Facts` struct, or a fact resource module whose persisted
  records expose `subject`, `predicate` and `value`. `opts` are forwarded to
  `Ash.read/2` on the resource path (`:actor`, `:tenant`, `:authorize?`, …).
  """
  @spec membership(t(), source(), keyword()) :: {:ok, Membership.t()} | {:error, term()}
  def membership(plan, facts, opts \\ [])

  def membership(%__MODULE__{} = plan, %Facts{} = memory, opts) do
    run(plan, memory, opts)
  end

  def membership(%__MODULE__{} = plan, triples, opts) when is_list(triples) do
    with {:ok, memory} <- Facts.prepare(plan.schema, triples) do
      run(plan, memory, opts)
    end
  end

  def membership(%__MODULE__{} = plan, resource, opts) when is_atom(resource) do
    with :ok <- validate_resource(resource) do
      run_over_resource(plan, resource, opts)
    end
  end

  # --- one evaluation, from per-probe subject sets -----------------------------

  # The partition falls out of set algebra over per-probe subject sets,
  # scanning probes in clause order: the first probe that decides a subject
  # decides it (unknown before out at the same probe), and survivors end up
  # in. This is exactly the direct evaluator's short-circuit conjunction,
  # per subject.
  @spec run(t(), Facts.t(), keyword()) :: {:ok, Membership.t()} | {:error, term()}
  defp run(plan, memory, _opts) do
    universe = universe_from_facts(memory)

    partition =
      plan.probes
      |> Enum.map(&probe_sets(&1, memory, universe))
      |> partition(universe)

    {:ok, to_membership(partition)}
  end

  defp universe_from_facts(%Facts{triples: triples}) do
    MapSet.new(MapSet.to_list(triples), &elem(&1, 0))
  end

  # exact: subjects with the probed fact (strict value equality); any:
  # subjects with any fact for the predicate. Both derive from the same
  # working-memory index the direct evaluator reads.
  @spec probe_sets(Probe.t(), Facts.t(), MapSet.t(term())) :: partition()
  defp probe_sets(%Probe{scope: :designated} = probe, memory, universe) do
    with_name = Facts.with_predicate(memory, probe.name)

    exact =
      with_name
      |> Enum.filter(fn {_s, _n, v} -> Ir.values_equal?(v, probe.value) end)
      |> MapSet.new(&elem(&1, 0))

    any = MapSet.new(with_name, &elem(&1, 0))
    designated_sets(probe, exact, any, universe)
  end

  defp probe_sets(%Probe{scope: {:context, subject}} = probe, memory, universe) do
    with_name = Facts.with_predicate(memory, probe.name)

    exact =
      with_name
      |> Enum.filter(fn {s, _n, v} ->
        Ir.values_equal?(s, subject) and Ir.values_equal?(v, probe.value)
      end)
      |> MapSet.new(&elem(&1, 0))

    any =
      with_name
      |> Enum.filter(fn {s, _n, _v} -> Ir.values_equal?(s, subject) end)
      |> MapSet.new(&elem(&1, 0))

    context_sets(probe, exact, any, universe)
  end

  # Absence resolution, matching `AshRules.Facts.absence/2`'s contract:
  # `:unknown` -> unknown; `:false`/`:no_fact` with a `false` probe -> the
  # synthesized triple is *present*; otherwise absence is a mismatch. What
  # "present" does to the partition is per op: for `has` it is a match, for
  # `neg` the negated triple existing is a failure.
  defp designated_sets(%Probe{op: op} = probe, exact, any, universe) do
    absent = MapSet.difference(universe, any)
    mismatch = MapSet.difference(any, exact)

    {present_absent, mismatch_absent, unknown_absent} =
      case split_absent(probe, absent) do
        :present -> {absent, MapSet.new(), MapSet.new()}
        :mismatch -> {MapSet.new(), absent, MapSet.new()}
        :unknown -> {MapSet.new(), MapSet.new(), absent}
      end

    case op do
      :has ->
        %{
          in: MapSet.union(exact, present_absent),
          out: MapSet.union(mismatch, mismatch_absent),
          unknown: unknown_absent
        }

      :neg ->
        %{
          in: MapSet.union(mismatch, mismatch_absent),
          out: MapSet.union(exact, present_absent),
          unknown: unknown_absent
        }
    end
  end

  # A context probe has one fixed answer for every member of the set.
  defp context_sets(%Probe{} = probe, exact, any, universe) do
    verdict =
      cond do
        MapSet.size(exact) > 0 -> probe.op == :has
        MapSet.size(any) > 0 -> probe.op == :neg
        probe.missing == :unknown -> :unknown
        synthesized?(probe) -> probe.op == :has
        true -> probe.op == :neg
      end

    case verdict do
      :unknown -> %{in: MapSet.new(), out: MapSet.new(), unknown: universe}
      true -> %{in: universe, out: MapSet.new(), unknown: MapSet.new()}
      false -> %{in: MapSet.new(), out: universe, unknown: MapSet.new()}
    end
  end

  defp split_absent(%Probe{missing: :unknown}, _absent), do: :unknown

  # Absence resolves as the value `false` would: a probe on `false` finds the
  # synthesized triple present; anything else is a mismatch (missing: :unknown
  # never reaches here, so the synthesized false cannot mask it).
  defp split_absent(%Probe{value: value}, _absent),
    do: if(value == false, do: :present, else: :mismatch)

  defp synthesized?(%Probe{value: value, missing: missing}),
    do: value == false and missing in [false, :no_fact]

  # --- set algebra --------------------------------------------------------------

  defp partition(probe_partitions, universe) do
    Enum.reduce(
      probe_partitions,
      %{in: universe, out: MapSet.new(), unknown: MapSet.new()},
      fn probe, acc ->
        decided = MapSet.union(probe.unknown, probe.out)

        %{
          in: MapSet.difference(acc.in, decided),
          out: MapSet.union(acc.out, MapSet.intersection(acc.in, probe.out)),
          unknown: MapSet.union(acc.unknown, MapSet.intersection(acc.in, probe.unknown))
        }
      end
    )
  end

  defp to_membership(%{in: in_set, out: out_set, unknown: unknown_set}) do
    %Membership{
      in: in_set |> MapSet.to_list() |> Enum.sort(),
      out: out_set |> MapSet.to_list() |> Enum.sort(),
      unknown: unknown_set |> MapSet.to_list() |> Enum.sort()
    }
  end

  # --- the resource path: compiled Ash queries ----------------------------------

  # Each probe narrows with two compiled Ash queries (pushdownable, indexable):
  # the probed fact rows and the any-value rows. The value filter is the data
  # layer's equality — a superset of the IR's strict equality under numeric
  # coercion — so candidates are re-verified with values_equal?/2 below. The
  # equivalence property test proves the two paths agree exactly.
  defp run_over_resource(plan, resource, opts) do
    with {:ok, universe_rows} <- read_subjects(universe_query(resource), opts) do
      universe = MapSet.new(universe_rows, & &1.subject)

      probe_partitions =
        Enum.map(plan.probes, fn probe ->
          with {:ok, exact_rows} <-
                 read_subjects(probe_query(resource, probe, exact?: true), opts),
               {:ok, any_rows} <- read_subjects(probe_query(resource, probe, exact?: false), opts) do
            exact =
              exact_rows
              |> Enum.filter(&Ir.values_equal?(&1.value, probe.value))
              |> MapSet.new(& &1.subject)

            any = MapSet.new(any_rows, & &1.subject)

            case probe.scope do
              :designated -> designated_sets(probe, exact, any, universe)
              {:context, _subject} -> context_sets(probe, exact, any, universe)
            end
          end
        end)

      case Enum.find(probe_partitions, &match?({:error, _}, &1)) do
        nil -> {:ok, to_membership(partition(probe_partitions, universe))}
        error -> error
      end
    end
  end

  defp universe_query(resource) do
    Ash.Query.select(resource, [:subject])
  end

  defp probe_query(resource, probe, exact?: exact?) do
    query =
      resource
      |> Ash.Query.filter(predicate == ^Atom.to_string(probe.name))

    query =
      if exact? do
        Ash.Query.filter(query, value == ^probe.value)
      else
        query
      end

    case probe.scope do
      {:context, subject} -> Ash.Query.filter(query, subject == ^subject)
      :designated -> query
    end
  end

  defp read_subjects(query, opts) do
    case Ash.read(query, opts) do
      {:ok, rows} -> {:ok, rows}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_resource(resource) do
    cond do
      not Ash.Resource.Info.resource?(resource) ->
        {:error,
         "#{inspect(resource)} is not an Ash resource. Pass a fact resource module, " <>
           "fact triples, or a prepared AshRules.Facts struct"}

      missing(resource) == [] ->
        :ok

      true ->
        {:error,
         "#{inspect(resource)} is not a fact table the set evaluator can query: missing " <>
           "attribute(s) #{inspect(missing(resource))} — a fact record exposes subject, " <>
           "predicate (string spelling of the IR name) and value"}
    end
  end

  defp missing(resource) do
    Enum.filter(@resource_attributes, &is_nil(Ash.Resource.Info.attribute(resource, &1)))
  end
end
