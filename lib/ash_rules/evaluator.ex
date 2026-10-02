# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator do
  @moduledoc """
  The evaluator behaviour: a bundle plus a working memory yields a result.

      @callback evaluate(AshRules.Ir.Bundle.t(), AshRules.Facts.t() | [AshRules.Facts.triple()], keyword()) ::
                  {:ok, AshRules.Result.t()} | {:error, term()}

  Two adapters ship:

    * `AshRules.Evaluator.Direct` — the default. Pure Elixir matching over the
      IR, no dependencies, deterministic by construction.
    * `AshRules.Evaluator.Wongi` — compiles the IR to Wongi.Engine rules with
      Generator productions and reads provenance from production tokens. Only
      compiled when the optional `wongi_engine` dependency is loadable; hosts
      without it get `{:error, :wongi_not_available}`.

  Both must produce identical results on the same bundle and facts; the test
  suite runs every golden case and a property corpus through both when Wongi
  is available.

  Alongside the behaviour sits `AshRules.Evaluator.Set` — the set evaluator of
  ADR 0048. It answers a different question over the same IR predicates: not
  "what is the outcome for this subject" but "which subjects are in, out,
  unknown", by compiling the predicates into Ash queries over facts. Its
  membership equals the per-subject outcome — the equivalence property test
  pins that to the direct evaluator.
  """

  alias AshRules.Facts
  alias AshRules.Ir.Bundle
  alias AshRules.Result

  @callback evaluate(Bundle.t(), Facts.t() | [Facts.triple()], keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc """
  Evaluates a bundle with the default evaluator (`AshRules.Evaluator.Direct`),
  or the one given as `opts[:evaluator]`.

  `facts` may be raw triples or a prepared `AshRules.Facts` struct. `opts[:seed]`
  is recorded on the result — evaluation is deterministic, so the seed is an
  audit marker, not an input to matching.
  """
  @spec evaluate(Bundle.t(), Facts.t() | [Facts.triple()], keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def evaluate(%Bundle{} = bundle, facts, opts \\ []) do
    evaluator = Keyword.get(opts, :evaluator, AshRules.Evaluator.Direct)
    evaluator.evaluate(bundle, facts, opts)
  end
end
