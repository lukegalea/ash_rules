# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules do
  @moduledoc """
  Compliance rules as data.

  `use AshRules` gives a module the rule DSL: a `fact_schema` describing what
  may be probed, and top-level `rule` declarations compiling into an immutable,
  content-hashed `AshRules.Ir.Bundle`. Evaluating the bundle against fact
  triples produces an `AshRules.Result` with per-requirement outcomes,
  provenance, and an overall outcome combined with the rule set's declared
  algorithm.

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
  """

  use Spark.Dsl, default_extensions: [extensions: [AshRules.Dsl]]

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
end
