# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.IrTest do
  use ExUnit.Case, async: true

  alias AshRules.Ir
  alias AshRules.Ir.{Bundle, Fact, FactSchema, OutcomeDeclaration, Predicate, Rule, Var}
  alias AshRules.TestSupport.RuleSets.KYC

  @valid_rule_json %{
    "id" => "kyc.required",
    "name" => "KYC required",
    "revision" => "2",
    "severity" => "high",
    "applicability" => [
      %{"op" => "has", "subject" => "customer", "name" => "status", "value" => "active"}
    ],
    "failure_conditions" => [
      %{"op" => "neg", "subject" => "customer", "name" => "has_kyc", "value" => true}
    ],
    "outcome" => %{"outcome" => "noncompliant", "gap" => "kyc.required"},
    "controls" => ["KYC-01"],
    "evidence" => [],
    "message" => "customer needs KYC"
  }

  @valid_schema_json [
    %{"name" => "status", "type" => "atom", "one_of" => ["active"], "missing" => "false"},
    %{"name" => "has_kyc", "type" => "boolean", "missing" => "unknown"}
  ]

  @valid_bundle_json %{
    "revision" => "7",
    "fact_schema_revision" => "3",
    "combining" => "deny_overrides",
    "fact_schema" => @valid_schema_json,
    "rules" => [@valid_rule_json]
  }

  describe "decode/1" do
    test "decodes a valid bundle document" do
      assert {:ok, %Bundle{} = bundle} = Ir.decode(@valid_bundle_json)

      assert [%Rule{} = rule] = bundle.rules
      assert rule.id == "kyc.required"
      assert rule.revision == "2"
      assert rule.severity == :high

      assert [%Predicate{op: :has, subject: "customer", name: :status, value: :active}] =
               rule.applicability

      assert [%Predicate{op: :neg, subject: "customer", name: :has_kyc, value: true}] =
               rule.failure_conditions

      assert %OutcomeDeclaration{outcome: :noncompliant, gap: "kyc.required"} = rule.outcome
      assert bundle.combining == :deny_overrides
      assert bundle.fact_schema.facts |> Enum.map(& &1.name) == [:has_kyc, :status]
      assert bundle.content_hash != nil
    end

    test "decodes variable references in subjects and values" do
      rule_json =
        put_in(@valid_rule_json, ["failure_conditions"], [
          %{
            "op" => "neg",
            "subject" => %{"var" => "account"},
            "name" => "has_kyc",
            "value" => %{"var" => "kyc_value"}
          }
        ])

      # :kyc_value is never bound -> refused (unbound variable)
      assert {:error, errors} = Ir.decode(%{@valid_bundle_json | "rules" => [rule_json]})
      assert errors |> Enum.join("\n") =~ "variable :kyc_value is used before it is bound"

      bound = [
        %{
          "op" => "has",
          "subject" => %{"var" => "account"},
          "name" => "status",
          "value" => "active"
        },
        %{"op" => "neg", "subject" => %{"var" => "account"}, "name" => "has_kyc", "value" => true}
      ]

      rule = put_in(@valid_rule_json, ["applicability"], bound)
      rule = put_in(rule, ["failure_conditions"], [])

      assert {:ok, %Bundle{} = bundle} = Ir.decode(%{@valid_bundle_json | "rules" => [rule]})

      assert [%Var{name: :account}, %Var{name: :account}] =
               hd(bundle.rules).applicability |> Enum.map(& &1.subject)
    end

    test "accepts JSON strings" do
      json = Jason.encode!(@valid_bundle_json)
      assert {:ok, %Bundle{}} = Ir.decode(json)
    end

    test "refuses garbage" do
      assert {:error, _} = Ir.decode(42)
      assert {:error, _} = Ir.decode(%{})
      assert {:error, "invalid JSON"} = Ir.decode("{not json")
    end

    # --- semantic refusals: the same verifiers the DSL applies -----------------

    test "refuses unknown predicates, naming the rule and the fix" do
      assert {:ok, %Bundle{}} = Ir.decode(@valid_bundle_json)

      bad_rule =
        put_in(@valid_rule_json, ["applicability"], [
          %{"op" => "has", "subject" => "customer", "name" => "nonsense", "value" => 1}
        ])

      assert {:error, errors} =
               Ir.decode(%{@valid_bundle_json | "rules" => [bad_rule]})

      assert Enum.any?(errors, &(&1 =~ ~r/predicate :nonsense is not in the fact schema/))

      assert Enum.any?(
               errors,
               &(&1 =~ ~r/Declare it in fact_schema with `fact :nonsense, :type`/)
             )
    end

    test "refuses value type mismatches" do
      bad_rule =
        put_in(@valid_rule_json, ["applicability"], [
          %{"op" => "has", "subject" => "customer", "name" => "has_kyc", "value" => "yes"}
        ])

      assert {:error, errors} = Ir.decode(%{@valid_bundle_json | "rules" => [bad_rule]})
      assert Enum.any?(errors, &(&1 =~ ~r/does not type-check against :boolean/))
    end

    test "refuses one_of violations" do
      bad_rule =
        put_in(@valid_rule_json, ["applicability"], [
          %{"op" => "has", "subject" => "customer", "name" => "status", "value" => "bogus"}
        ])

      # note: the JSON value is a string; it decodes to an atom that is not in one_of
      assert {:error, errors} = Ir.decode(%{@valid_bundle_json | "rules" => [bad_rule]})
      assert Enum.any?(errors, &(&1 =~ ~r/is outside one_of \[:active\]/))
    end

    test "refuses missing severity, outcome and gap" do
      rule = Map.merge(@valid_rule_json, %{"severity" => nil, "outcome" => nil})
      assert {:error, errors} = Ir.decode(%{@valid_bundle_json | "rules" => [rule]})
      assert Enum.any?(errors, &(&1 =~ ~r/no severity declared/))
      assert Enum.any?(errors, &(&1 =~ ~r/no outcome declared/))

      rule = put_in(@valid_rule_json, ["outcome"], %{"outcome" => "noncompliant"})
      assert {:error, errors} = Ir.decode(%{@valid_bundle_json | "rules" => [rule]})
      assert Enum.any?(errors, &(&1 =~ ~r/outcome :noncompliant has no gap/))
    end

    test "refuses a rule asserting compliant when it fires" do
      rule =
        put_in(@valid_rule_json, ["outcome"], %{"outcome" => "compliant", "gap" => "x.y"})

      assert {:error,
              "rule: outcome declaration: a rule cannot assert outcome :compliant when it fires"} =
               Ir.decode(%{@valid_bundle_json | "rules" => [rule]})
    end

    test "refuses duplicate rule ids" do
      assert {:error, errors} =
               Ir.decode(%{@valid_bundle_json | "rules" => [@valid_rule_json, @valid_rule_json]})

      assert Enum.any?(errors, &(&1 =~ ~r/id is declared more than once/))
    end

    test "refuses unknown severity values" do
      rule = put_in(@valid_rule_json, ["severity"], "catastrophic")

      assert {:error,
              "rule: severity \"catastrophic\" is not one of [:low, :medium, :high, :critical]"} =
               Ir.decode(%{@valid_bundle_json | "rules" => [rule]})
    end

    test "refuses bad fact schema entries" do
      assert {:error, "fact schema entry: type \"bogus\" is not one of" <> _} =
               Ir.decode(%{
                 @valid_bundle_json
                 | "fact_schema" => [%{"name" => "x", "type" => "bogus"}]
               })

      assert {:error, "fact schema entry: missing \"bogus\" is not one of" <> _} =
               Ir.decode(%{
                 @valid_bundle_json
                 | "fact_schema" => [%{"name" => "x", "type" => "atom", "missing" => "bogus"}]
               })
    end
  end

  describe "encode/decode round trip" do
    test "a compiled bundle survives a JSON round trip" do
      bundle = KYC.__bundle__()

      # The content hash — the auditable identity of the bundle — is stable:
      # the wire form encodes subjects opaquely, and decoding reproduces the
      # exact same canonical JSON.
      assert {:ok, decoded} = Ir.decode(Ir.encode!(bundle))
      assert decoded.content_hash == bundle.content_hash

      # decode ∘ encode is idempotent from the first decode on
      assert {:ok, decoded_again} = Ir.decode(Ir.encode!(decoded))
      assert decoded_again == decoded
    end
  end

  describe "content hash" do
    test "is stable across declaration order" do
      bundle = KYC.__bundle__()

      reordered =
        Bundle.new(
          Enum.reverse(bundle.rules),
          Enum.reverse(bundle.fact_schema.facts),
          combining: :deny_overrides
        )

      assert reordered.content_hash == bundle.content_hash
    end

    test "changes when a rule changes" do
      bundle = KYC.__bundle__()

      [first | rest] = bundle.rules
      changed = %{bundle | rules: [%{first | severity: :critical} | rest]}

      refute Bundle.content_hash(changed) == bundle.content_hash
    end

    test "changes when the fact schema changes" do
      bundle = KYC.__bundle__()

      facts = bundle.fact_schema.facts

      changed = %{
        bundle
        | fact_schema: %{
            bundle.fact_schema
            | facts: [%{hd(facts) | description: "changed"} | tl(facts)]
          }
      }

      refute Bundle.content_hash(changed) == bundle.content_hash
    end
  end

  describe "Fact" do
    test "valid_value? type-checks runtime values" do
      fact = Fact.new(:status, :atom, one_of: [:active])

      assert Fact.valid_value?(fact, :active)
      refute Fact.valid_value?(fact, :bogus)
      refute Fact.valid_value?(fact, "active")
      refute Fact.valid_value?(fact, true)

      assert Fact.valid_value?(Fact.new(:n, :integer), 3)
      refute Fact.valid_value?(Fact.new(:n, :integer), 3.5)
      assert Fact.valid_value?(Fact.new(:n, :number), 3.5)
      assert Fact.valid_value?(Fact.new(:n, :number), 3)
      assert Fact.valid_value?(Fact.new(:d, :date), Date.utc_today())
      assert Fact.valid_value?(Fact.new(:d, :any), {:anything, :goes})
    end

    test "absence defaults to :false" do
      assert Fact.new(:x, :boolean).missing == false
      assert Fact.new(:x, :boolean, missing: :unknown).missing == :unknown
    end
  end

  describe "FactSchema" do
    test "fetches by name and sorts entries" do
      schema =
        FactSchema.new([Fact.new(:zzz, :boolean), Fact.new(:aaa, :boolean)])

      assert schema.facts |> Enum.map(& &1.name) == [:aaa, :zzz]
      assert {:ok, %Fact{name: :zzz}} = FactSchema.fetch(schema, :zzz)
      assert :error = FactSchema.fetch(schema, :nope)
      assert FactSchema.declares?(schema, :aaa)
      refute FactSchema.declares?(schema, :nope)
    end
  end

  describe "values_equal?/2" do
    test "is strict, with no numeric type coercion" do
      assert Ir.values_equal?(80, 80)
      refute Ir.values_equal?(80, 80.0)
      refute Ir.values_equal?(:a, "a")
      assert Ir.values_equal?(%Date{year: 2026, month: 1, day: 1}, ~D[2026-01-01])
    end
  end
end
