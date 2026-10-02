# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules do
  @moduledoc """
  A judgment is a predicate over any set (ADR 0048).

  `use AshRules` gives a module the rule DSL: a `fact_schema` describing what
  may be probed, and top-level `rule` declarations compiling into an immutable,
  content-hashed `AshRules.Ir.Bundle`. Evaluating the bundle against fact
  triples produces an `AshRules.Result` with per-requirement outcomes,
  provenance, and an overall outcome combined with the rule set's declared
  algorithm. The same declared predicates evaluate over sets of subjects —
  filters, search, segments — as three-valued membership. Compliance is the
  first consumer of that vocabulary, not the whole of it.

      defmodule MyApp.Compliance.Rules do
        use AshRules

        fact_schema do
          fact :status, :atom, one_of: [:active, :suspended]
          fact :jurisdiction, :atom
          fact :has_valid_kyc, :boolean, missing: :unknown
        end

        rule "active regulated customer requires valid KYC",
          id: "kyc.valid_required",
          severity: :medium do
          when_requires has(:customer, :status, :active),
                        has(:customer, :jurisdiction, :regulated)
          fails_when neg(:customer, :has_valid_kyc, true)
          outcome :noncompliant, gap: "kyc.valid_required"
        end
      end

      bundle = MyApp.Compliance.Rules.__bundle__()

      AshRules.evaluate(bundle, [
        {:customer, :status, :active},
        {:customer, :jurisdiction, :regulated}
      ])
      #=> {:ok, %AshRules.Result{overall: :unknown, ...}}

  The evaluation above is `:unknown`, not `:noncompliant`: `has_valid_kyc` is
  declared `missing: :unknown` and no fact supplies it. Absence of data never
  becomes a violation — or a pass.

  The same declared predicates evaluate over *sets*: `AshRules.membership/4`
  compiles IR predicates into Ash queries over facts and partitions subjects
  into `in`, `out` and `unknown` (ADR 0048 — a judgment is a predicate over
  any set; the equivalence property test proves set membership equals the
  per-subject outcome). `AshRules.Standings` diffs those partitions into
  membership-change events (`:entered` / `:left` / `:became_unknown`) and
  hands them to a host dispatcher — the standing-query seam for BPMN starts,
  signals and notifications.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshRules.Dsl]]

  alias AshRules.Evaluator.Set
  alias AshRules.Facts
  alias AshRules.Ir.Bundle
  alias AshRules.Result

  @doc false
  def handle_before_compile(_opts) do
    quote do
      @doc "The compiled, content-hashed `AshRules.Ir.Bundle` for this rule set."
      @spec __bundle__() :: AshRules.Ir.Bundle.t()
      def __bundle__, do: AshRules.Info.bundle!(__MODULE__)

      @doc "The compiled `AshRules.Ir.Rule` structs of this rule set, in id order."
      @spec __rules__() :: [AshRules.Ir.Rule.t()]
      def __rules__, do: __bundle__().rules
    end
  end

  @doc """
  Evaluates a rule set module (or a bundle) against fact triples.

  Options:

    * `:evaluator` — the evaluator module; defaults to
      `AshRules.Evaluator.Direct`.
    * `:seed` — recorded on the result as an audit marker (evaluation is
      deterministic; the seed does not influence matching).
  """
  @spec evaluate(module() | Bundle.t(), AshRules.Facts.t() | [AshRules.Facts.triple()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def evaluate(module_or_bundle, facts, opts \\ [])

  def evaluate(module, facts, opts) when is_atom(module) do
    evaluate(module.__bundle__(), facts, opts)
  end

  def evaluate(%Bundle{} = bundle, facts, opts) do
    AshRules.Evaluator.evaluate(bundle, facts, opts)
  end

  @doc """
  Evaluates a conjunction of IR predicates over a *set* of subjects:
  compiles the predicates (against a rule-set module, bundle or fact schema)
  and partitions the subjects present in `source` into `in`, `out` and
  `unknown`.

      {:ok, membership} =
        AshRules.membership(MyApp.Compliance.Rules, [has(var(:s), :has_valid_kyc, true)], facts)

      membership.in      #=> subjects an admitted fact puts in
      membership.unknown #=> subjects with no deciding fact — never folded either way

  `source` is raw fact triples, a prepared `AshRules.Facts` struct, or a fact
  resource module (`subject`, `predicate`, `value` attributes) whose queries
  run through `Ash.read/2` with `opts` forwarded. See
  `AshRules.Evaluator.Set` for the membership semantics and the v0 shape of a
  set expression.
  """
  @spec membership(
          module() | Bundle.t() | AshRules.Ir.FactSchema.t(),
          [
            AshRules.Ir.Predicate.t()
          ],
          Facts.t() | [Facts.triple()] | module(),
          keyword()
        ) ::
          {:ok, Set.Membership.t()} | {:error, term()}
  def membership(module_or_bundle, predicates, source, opts \\ [])

  def membership(module, predicates, source, opts)
      when is_atom(module) and not is_boolean(module) do
    membership(module.__bundle__(), predicates, source, opts)
  end

  def membership(%Bundle{} = bundle, predicates, source, opts) do
    Set.membership(bundle, predicates, source, opts)
  end

  def membership(%AshRules.Ir.FactSchema{} = schema, predicates, source, opts) do
    Set.membership(schema, predicates, source, opts)
  end
end
