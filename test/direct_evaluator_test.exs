# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator.DirectTest do
  use ExUnit.Case, async: true

  alias AshRules.Evaluator.Direct
  alias AshRules.Result
  alias AshRules.Result.Requirement
  alias AshRules.TestSupport.RuleSets.KYC

  @bundle KYC.__bundle__()

  defp evaluate(facts, opts \\ []) do
    Direct.evaluate(@bundle, facts, opts)
  end

  defp requirement(result, rule_id) do
    Enum.find(result.requirements, &(&1.rule_id == rule_id))
  end

  # --- golden: everything known, everything fine ------------------------------

  @golden_ok_facts [
    {:customer, :status, :active},
    {:customer, :jurisdiction, :regulated},
    {:customer, :has_valid_kyc, true},
    {:customer, :reviewed_at, true},
    {:checking, :owner, :customer},
    {:checking, :balance, 0}
  ]

  describe "golden evaluation" do
    test "all facts known, all rules satisfied — exact result" do
      {:ok, result} = evaluate(@golden_ok_facts)

      assert result == %Result{
               bundle_hash: @bundle.content_hash,
               bundle_revision: "1",
               fact_schema_revision: "1",
               combining: :deny_overrides,
               evaluator: Direct,
               seed: nil,
               overall: :compliant,
               derived_facts: [],
               missing_facts: [],
               requirements: [
                 %Requirement{
                   rule_id: "acct.balance_frozen",
                   rule_revision: "1",
                   severity: :low,
                   gap: "acct.balance",
                   outcome: :not_applicable,
                   message: nil,
                   bindings: [],
                   consumed_facts: [],
                   probed_facts: [{:customer, :status, :suspended}],
                   missing_facts: []
                 },
                 %Requirement{
                   rule_id: "kyc.review_required",
                   rule_revision: "1",
                   severity: :high,
                   gap: "kyc.review",
                   outcome: :compliant,
                   message: nil,
                   bindings: [],
                   consumed_facts: [{:customer, :status, :active}],
                   probed_facts: [{:customer, :reviewed_at, true}],
                   missing_facts: []
                 },
                 %Requirement{
                   rule_id: "kyc.valid_required",
                   rule_revision: "1",
                   severity: :medium,
                   gap: "kyc.valid_required",
                   outcome: :compliant,
                   message: nil,
                   bindings: [],
                   consumed_facts: [
                     {:customer, :jurisdiction, :regulated},
                     {:customer, :status, :active}
                   ],
                   probed_facts: [{:customer, :has_valid_kyc, true}],
                   missing_facts: []
                 }
               ]
             }
    end

    test "a violation fires with provenance, bindings and a rendered message" do
      facts = [
        {:customer, :status, :suspended},
        {:customer, :jurisdiction, :regulated},
        {:customer, :has_valid_kyc, false},
        {:checking, :owner, :customer},
        {:checking, :balance, 250}
      ]

      {:ok, result} = evaluate(facts)

      assert result.overall == :noncompliant
      assert result.derived_facts == [{"acct.balance_frozen", :finding, 1}]
      assert result.missing_facts == []

      finding = requirement(result, "acct.balance_frozen")
      assert finding.outcome == :noncompliant
      assert finding.bindings == [%{account: :checking}]
      assert finding.message == "account checking holds a non-zero balance while suspended"

      assert finding.consumed_facts == [
               {:checking, :owner, :customer},
               {:customer, :status, :suspended}
             ]

      assert finding.probed_facts == [{:checking, :balance, 0}]

      # not applicable: the customer is not active
      assert requirement(result, "kyc.valid_required").outcome == :not_applicable
      assert requirement(result, "kyc.review_required").outcome == :not_applicable
    end

    test "missing data makes the rule unknown, never compliant or falsely negative" do
      facts = [
        {:customer, :status, :active},
        {:customer, :jurisdiction, :regulated}
      ]

      {:ok, result} = evaluate(facts)

      kyc = requirement(result, "kyc.valid_required")
      assert kyc.outcome == :unknown
      assert kyc.missing_facts == [{:customer, :has_valid_kyc, true}]
      assert kyc.consumed_facts == []
      assert kyc.bindings == []
      assert result.missing_facts == [{:customer, :has_valid_kyc, true}]

      # no_fact semantics: absence is the expected state and the rule fires on it
      review = requirement(result, "kyc.review_required")
      assert review.outcome == :noncompliant
      assert review.missing_facts == []

      assert result.overall == :noncompliant
    end
  end

  describe "combining via evaluation" do
    test "permit_overrides flips the overall outcome relative to deny_overrides" do
      bundle = AshRules.TestSupport.RuleSets.KYCPermitOverrides.__bundle__()
      facts = [{:customer, :status, :active}, {:customer, :flag, false}]

      {:ok, result} = Direct.evaluate(bundle, facts, [])
      outcomes = Enum.map(result.requirements, & &1.outcome)

      assert result.overall == :compliant
      assert AshRules.Combining.deny_overrides(outcomes) == :noncompliant
    end

    test "permit_overrides lets one compliant rule decide over a violation" do
      bundle = AshRules.TestSupport.RuleSets.KYCPermitOverrides.__bundle__()

      facts = [
        {:customer, :status, :active},
        {:customer, :flag, false},
        {:customer, :checked, false}
      ]

      {:ok, result} = Direct.evaluate(bundle, facts, [])
      outcomes = Enum.map(result.requirements, &{&1.rule_id, &1.outcome})

      assert outcomes == [
               {"checked.ok", :compliant},
               {"flag.required", :noncompliant}
             ]

      assert result.overall == :compliant
    end
  end

  describe "determinism" do
    test "repeated evaluation is byte-identical (n=50)" do
      facts = [
        {:customer, :status, :active},
        {:customer, :jurisdiction, :regulated},
        {:checking, :owner, :customer},
        {:checking, :balance, 42}
      ]

      results =
        for _n <- 1..50 do
          {:ok, result} = evaluate(facts)
          result
        end

      assert Enum.uniq(results) == [hd(results)]
    end

    test "fact order does not matter" do
      facts_a = [
        {:customer, :status, :active},
        {:customer, :jurisdiction, :regulated},
        {:customer, :has_valid_kyc, true}
      ]

      facts_b = Enum.reverse(facts_a)

      {:ok, a} = evaluate(facts_a)
      {:ok, b} = evaluate(facts_b)
      assert a == b
    end

    test "the seed is recorded but does not influence matching" do
      {:ok, plain} = evaluate(@golden_ok_facts)
      {:ok, seeded} = evaluate(@golden_ok_facts, seed: "audit-2026-09-17")

      assert %{seeded | seed: nil} == plain
      assert seeded.seed == "audit-2026-09-17"
    end
  end

  describe "fact validation" do
    test "refuses facts outside the schema, naming the fact and the fix" do
      assert {:error, message} = evaluate([{:customer, :nonsense, 1}])

      assert message =~ "predicate :nonsense is not in the fact schema"
      assert message =~ "or drop the fact"
    end

    test "refuses type-violating values" do
      assert {:error, message} = evaluate([{:customer, :balance, "many"}])
      assert message =~ "does not type-check against :integer"
    end

    test "refuses one_of violations" do
      assert {:error, message} = evaluate([{:customer, :status, :deleted}])
      assert message =~ "does not type-check against :atom (one_of: [:active, :suspended])"
    end

    test "refuses non-triple facts" do
      assert {:error, message} = evaluate([{:customer, :status}])
      assert message =~ "facts must be {subject, predicate, value} triples"
    end
  end

  describe "variable binding" do
    test "one finding per matched binding, deterministically indexed" do
      defmodule MultiBinding do
        use AshRules

        fact_schema do
          fact(:owner, :atom)
          fact(:balance, :integer)
        end

        rule "overdrawn accounts", id: "acct.overdrawn", severity: :high do
          when_requires(
            has(var(:account), :owner, :customer),
            has(var(:account), :balance, var(:b))
          )

          fails_when(has(var(:account), :balance, var(:b)))
          outcome(:noncompliant, gap: "acct.overdrawn")
        end
      end

      bundle = MultiBinding.__bundle__()

      facts = [
        {:a2, :owner, :customer},
        {:a1, :owner, :customer},
        {:a1, :balance, 5},
        {:a2, :balance, 7},
        {:a3, :owner, :customer},
        {:a3, :balance, 0}
      ]

      {:ok, result} = Direct.evaluate(bundle, facts, [])
      finding = hd(result.requirements)

      # accounts bound in sorted order; a3 (balance 0) also binds — the rule
      # has no neg clause, so every owned account with a balance matches
      assert finding.bindings == [
               %{account: :a1, b: 5},
               %{account: :a2, b: 7},
               %{account: :a3, b: 0}
             ]

      assert result.derived_facts == [
               {"acct.overdrawn", :finding, 1},
               {"acct.overdrawn", :finding, 2},
               {"acct.overdrawn", :finding, 3}
             ]

      assert result.overall == :noncompliant
    end

    test "variables unify across clauses" do
      defmodule Unify do
        use AshRules

        fact_schema do
          fact(:mirror, :atom)
          fact(:exists, :boolean)
        end

        rule "self-mirroring entities must exist", id: "u.mirror", severity: :low do
          when_requires(has(var(:s), :mirror, var(:s)))
          fails_when(neg(var(:s), :exists, true))
          outcome(:noncompliant, gap: "u.mirror")
        end
      end

      bundle = Unify.__bundle__()

      facts = [{:alpha, :mirror, :alpha}, {:alpha, :exists, true}, {:beta, :mirror, :beta}]
      {:ok, result} = Direct.evaluate(bundle, facts, [])

      finding = hd(result.requirements)
      assert finding.outcome == :noncompliant
      assert finding.bindings == [%{s: :beta}]
    end
  end

  describe "message rendering" do
    test "renders %{placeholders} from bindings and leaves unknowns intact" do
      defmodule Messages do
        use AshRules

        fact_schema do
          fact(:region, :atom)
          fact(:quota_used, :boolean)
        end

        rule "quota used",
          id: "m.quota",
          severity: :low,
          message: "subject %{subject} exceeded quota (%{missing_key})" do
          when_requires(has(var(:subject), :region, :emea))
          fails_when(has(var(:subject), :quota_used, true))
          outcome(:noncompliant, gap: "m.quota")
        end
      end

      bundle = Messages.__bundle__()
      facts = [{:cust1, :region, :emea}, {:cust1, :quota_used, true}]
      {:ok, result} = Direct.evaluate(bundle, facts, [])

      assert hd(result.requirements).message == "subject cust1 exceeded quota (%{missing_key})"
    end

    test "defaults to the rule name" do
      bundle = KYC.__bundle__()
      facts = [{:customer, :status, :active}, {:customer, :jurisdiction, :regulated}]

      {:ok, result} = Direct.evaluate(bundle, facts, [])

      assert requirement(result, "kyc.review_required").message ==
               "active regulated customer requires a recorded review"
    end
  end

  describe "evaluate through AshRules facade" do
    test "accepts a module and passes opts through" do
      {:ok, result} = AshRules.evaluate(KYC, @golden_ok_facts, seed: :x)
      assert result.overall == :compliant
      assert result.evaluator == Direct
      assert result.seed == :x
    end

    test "honours the :evaluator option" do
      {:ok, direct} = AshRules.evaluate(@bundle, @golden_ok_facts, evaluator: Direct)
      assert direct.evaluator == Direct
    end
  end
end
