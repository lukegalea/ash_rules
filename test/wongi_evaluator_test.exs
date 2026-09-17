# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator.WongiTest do
  use ExUnit.Case, async: true

  # Note: only the engine module is aliased, so `Wongi.Engine` below refers to
  # the real engine, not a nested module of the adapter.
  alias Wongi.Engine

  @moduletag :wongi

  if Code.ensure_loaded?(:"Elixir.Wongi.Engine") do
    @adapter AshRules.Evaluator.Wongi
    @direct AshRules.Evaluator.Direct
    @bundle AshRules.TestSupport.RuleSets.KYC.__bundle__()

    @golden_facts [
      {:customer, :status, :active},
      {:customer, :jurisdiction, :regulated},
      {:customer, :has_valid_kyc, true},
      {:customer, :reviewed_at, true},
      {:checking, :owner, :customer},
      {:checking, :balance, 0}
    ]

    @violation_facts [
      {:customer, :status, :suspended},
      {:customer, :jurisdiction, :regulated},
      {:customer, :has_valid_kyc, false},
      {:checking, :owner, :customer},
      {:checking, :balance, 250}
    ]

    @unknown_facts [
      {:customer, :status, :active},
      {:customer, :jurisdiction, :regulated}
    ]

    defp parity(facts) do
      {:ok, direct} = @direct.evaluate(@bundle, facts, [])
      {:ok, wongi} = @adapter.evaluate(@bundle, facts, [])

      # decisions: outcomes, revisions, severities, gaps, bindings, messages
      assert projected(wongi.requirements) == projected(direct.requirements)

      # derived facts and missing facts agree
      assert wongi.derived_facts == direct.derived_facts
      assert wongi.missing_facts == direct.missing_facts

      # overall outcome agrees
      assert wongi.overall == direct.overall
      assert wongi.bundle_hash == direct.bundle_hash

      # fired requirements carry identical consumed-fact provenance
      for {d, w} <- Enum.zip(direct.requirements, wongi.requirements),
          d.outcome not in [:compliant, :not_applicable, :unknown] do
        assert w.consumed_facts == d.consumed_facts
      end

      {direct, wongi}
    end

    defp projected(requirements) do
      Enum.map(requirements, fn requirement ->
        Map.take(requirement, [
          :rule_id,
          :rule_revision,
          :severity,
          :gap,
          :outcome,
          :message,
          :bindings,
          :missing_facts
        ])
      end)
    end

    test "golden parity: all facts known" do
      {direct, wongi} = parity(@golden_facts)
      assert direct.overall == :compliant
      assert wongi.overall == :compliant
    end

    test "golden parity: a violation fires identically" do
      {direct, wongi} = parity(@violation_facts)

      assert direct.overall == :noncompliant
      assert wongi.overall == :noncompliant

      finding = Enum.find(wongi.requirements, &(&1.rule_id == "acct.balance_frozen"))
      assert finding.outcome == :noncompliant
      assert finding.bindings == [%{account: :checking}]
      assert finding.message == "account checking holds a non-zero balance while suspended"

      assert finding.consumed_facts == [
               {:checking, :owner, :customer},
               {:customer, :status, :suspended}
             ]
    end

    test "golden parity: missing data yields unknown identically" do
      {direct, wongi} = parity(@unknown_facts)

      # kyc.review_required fires (no_fact absence is the expected state);
      # kyc.valid_required is unknown (kyc data missing); deny_overrides
      # takes the worst applicable outcome.
      assert direct.overall == :noncompliant
      assert wongi.overall == :noncompliant

      kyc = Enum.find(wongi.requirements, &(&1.rule_id == "kyc.valid_required"))
      assert kyc.outcome == :unknown
      assert kyc.missing_facts == [{:customer, :has_valid_kyc, true}]
    end

    test "refuses facts that are not in the schema, identically" do
      bad = [{:customer, :nonsense, 1}]
      assert @direct.evaluate(@bundle, bad, []) == @adapter.evaluate(@bundle, bad, [])
    end

    test "engine/2 builds a live engine keyed by domain rule ids" do
      assert {:ok, %{engine: engine, failure_refs: refs}} =
               @adapter.engine(@bundle, @violation_facts)

      assert Map.has_key?(refs, "acct.balance_frozen")
      findings = Engine.select(engine, {"acct.balance_frozen", :finding, :_})
      assert MapSet.size(findings) == 1

      # engine refs never leak into results
      assert {:ok, result} = @adapter.evaluate(@bundle, @violation_facts, [])
      refute inspect(result) =~ "#Reference<"
    end

    test "truth maintenance: retracting a premise retracts the finding" do
      assert {:ok, %{engine: engine}} = @adapter.engine(@bundle, @violation_facts)

      findings = fn engine ->
        Engine.select(engine, {"acct.balance_frozen", :finding, :_})
      end

      assert MapSet.size(findings.(engine)) == 1

      # retract a supporting premise: the finding goes with it
      engine = Engine.retract(engine, {:checking, :owner, :customer})
      assert MapSet.size(findings.(engine)) == 0

      # re-asserting the premise re-derives the finding
      engine = Engine.assert(engine, {:checking, :owner, :customer})
      assert MapSet.size(findings.(engine)) == 1

      # asserting the negated fact (balance reaching zero) also kills it
      engine = Engine.assert(engine, {:checking, :balance, 0})
      assert MapSet.size(findings.(engine)) == 0
    end

    test "derived facts are retracted when their support disappears" do
      {:ok, %{engine: engine}} = @adapter.engine(@bundle, @violation_facts)
      assert MapSet.size(Engine.select(engine, {"acct.balance_frozen", :finding, :_})) == 1

      engine = Engine.retract(engine, {:checking, :owner, :customer})
      assert MapSet.size(Engine.select(engine, {"acct.balance_frozen", :finding, :_})) == 0
    end
  else
    test "wongi adapter is not available in this build" do
      assert {:error, :wongi_not_available} =
               AshRules.Evaluator.Wongi.evaluate(:no_bundle, [], [])
    end
  end
end
