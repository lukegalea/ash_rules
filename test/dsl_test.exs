# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.DslTest do
  use ExUnit.Case, async: true

  alias AshRules.Info

  describe "compilation" do
    test "exposes the compiled bundle and rules" do
      bundle = AshRules.TestSupport.RuleSets.KYC.__bundle__()

      assert %AshRules.Ir.Bundle{} = bundle
      assert bundle.combining == :deny_overrides
      assert bundle.revision == "1"

      rules = AshRules.TestSupport.RuleSets.KYC.__rules__()
      assert rules == bundle.rules

      assert Enum.map(rules, & &1.id) == [
               "acct.balance_frozen",
               "kyc.review_required",
               "kyc.valid_required"
             ]
    end

    test "rules carry their metadata into the IR" do
      rule =
        AshRules.TestSupport.RuleSets.KYC.__rules__()
        |> Enum.find(&(&1.id == "kyc.valid_required"))

      assert rule.name == "active regulated customer requires valid KYC"
      assert rule.severity == :medium
      assert rule.remediation_ref == "runbooks/kyc-verification"
      assert rule.evidence == ["kyc.vendor_result"]
      assert rule.source == "Policy 4.1"
      assert rule.outcome.outcome == :noncompliant
      assert rule.outcome.gap == "kyc.valid_required"
      assert length(rule.applicability) == 2
      assert [%{op: :neg, name: :has_valid_kyc, value: true}] = rule.failure_conditions
    end

    test "Info accessors read the compiled DSL" do
      module = AshRules.TestSupport.RuleSets.KYC

      assert {:ok, bundle} = Info.bundle(module)
      assert bundle == Info.bundle!(module)

      assert Enum.map(Info.rules(module), & &1.id) == [
               "acct.balance_frozen",
               "kyc.review_required",
               "kyc.valid_required"
             ]

      assert Info.combining(module) == :deny_overrides

      assert Info.fact_schema(module).facts |> Enum.map(& &1.name) ==
               [:balance, :has_valid_kyc, :jurisdiction, :owner, :reviewed_at, :status]
    end

    test "bundle!/1 raises on a non-rule-set module with the fix" do
      assert_raise ArgumentError, ~r/not an AshRules module.*use AshRules/s, fn ->
        Info.bundle!(String)
      end
    end

    test "two modules with identical content hash identically" do
      defmodule HashA do
        use AshRules

        fact_schema do
          fact(:flag, :boolean)
        end

        rule "flag", id: "a.flag", severity: :low do
          when_requires(has(:customer, :flag, false))
          outcome(:noncompliant, gap: "a.flag")
        end
      end

      defmodule HashB do
        use AshRules

        fact_schema do
          fact(:flag, :boolean)
        end

        rule "flag", id: "a.flag", severity: :low do
          when_requires(has(:customer, :flag, false))
          outcome(:noncompliant, gap: "a.flag")
        end
      end

      assert HashA.__bundle__().content_hash == HashB.__bundle__().content_hash
    end

    test "combining defaults to deny_overrides and accepts explicit algorithms" do
      defmodule DefaultCombining do
        use AshRules

        fact_schema do
          fact(:flag, :boolean)
        end

        rule "r", id: "d.r", severity: :low do
          outcome(:noncompliant, gap: "d.r")
        end
      end

      assert DefaultCombining.__bundle__().combining == :deny_overrides

      assert AshRules.TestSupport.RuleSets.KYCPermitOverrides.__bundle__().combining ==
               :permit_overrides
    end

    test "an empty applicability means the rule always applies" do
      defmodule AlwaysApplies do
        use AshRules

        fact_schema do
          fact(:flag, :boolean)
        end

        rule "unconditional", id: "u.r", severity: :low do
          outcome(:noncompliant, gap: "u.r")
        end
      end

      bundle = AlwaysApplies.__bundle__()
      assert [%{applicability: []}] = bundle.rules

      assert {:ok, result} = AshRules.evaluate(bundle, [])
      assert [%{outcome: :noncompliant}] = result.requirements
    end
  end

  # Verifier refusals surface as compiler diagnostics: they fail any build
  # running with --warnings-as-errors (the project's compile gate) and print
  # the refusal naming the rule and the fix. Each negative test quotes its
  # refusal.
  defp compile_dsl(source) do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string(source, "test_dsl.exs")
    end)
  end

  describe "verifier refusals (unknown predicate)" do
    @tag :dsl_negative
    test "unknown predicate" do
      output =
        compile_dsl("""
        defmodule Bad.UnknownPredicate do
          use AshRules

          fact_schema do
            fact :status, :atom
          end

          rule "r", id: "x.r", severity: :low do
            when_requires has(:customer, :nonsense, 1)
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "rule \"x.r\": predicate :nonsense is not in the fact schema"
      assert output =~ "Declare it in fact_schema with `fact :nonsense, :type`"
    end

    @tag :dsl_negative
    test "value type mismatch" do
      output =
        compile_dsl("""
        defmodule Bad.TypeMismatch do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :low do
            when_requires has(:customer, :flag, "yes")
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "predicate :flag value \"yes\" does not type-check against :boolean"
      assert output =~ "Use a boolean value"
    end

    @tag :dsl_negative
    test "one_of violation" do
      output =
        compile_dsl("""
        defmodule Bad.OneOf do
          use AshRules

          fact_schema do
            fact :status, :atom, one_of: [:active, :suspended]
          end

          rule "r", id: "x.r", severity: :low do
            when_requires has(:customer, :status, :deleted)
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~
               "value :deleted does not type-check against :atom (one_of: [:active, :suspended])"
    end

    @tag :dsl_negative
    test "unbound variable in neg" do
      output =
        compile_dsl("""
        defmodule Bad.UnboundVar do
          use AshRules

          fact_schema do
            fact :owner, :atom
          end

          rule "r", id: "x.r", severity: :low do
            when_requires has(:customer, :owner, :customer)
            fails_when neg(var(:account), :owner, :nobody)
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "variable :account is used before it is bound"
      assert output =~ "Bind it with an earlier has(...) clause in when_requires"
    end

    @tag :dsl_negative
    test "missing severity" do
      output =
        compile_dsl("""
        defmodule Bad.NoSeverity do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r" do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "rule \"x.r\": no severity declared"
      assert output =~ "Add `severity: :low | :medium | :high | :critical` to the rule"
    end

    @tag :dsl_negative
    test "missing outcome" do
      output =
        compile_dsl("""
        defmodule Bad.NoOutcome do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :medium do
            when_requires has(:customer, :flag, true)
          end
        end
        """)

      assert output =~ "rule \"x.r\": no outcome declared"

      assert output =~
               "Add `outcome :noncompliant, gap: \"<control reference>\"` to the rule body"
    end

    @tag :dsl_negative
    test "noncompliant outcome without gap (combining metadata)" do
      output =
        compile_dsl("""
        defmodule Bad.NoGap do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :medium do
            outcome :noncompliant
          end
        end
        """)

      assert output =~ "outcome :noncompliant has no gap"
      assert output =~ "Combining metadata must be present at every level"
    end

    @tag :dsl_negative
    test "duplicate rule id" do
      output =
        compile_dsl("""
        defmodule Bad.DuplicateId do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "first", id: "dup.r", severity: :low do
            outcome :noncompliant, gap: "dup.r"
          end

          rule "second", id: "dup.r", severity: :low do
            outcome :noncompliant, gap: "dup.r"
          end
        end
        """)

      assert output =~ "rule \"dup.r\": id is declared more than once"
      assert output =~ "Rule ids must be unique"
    end

    @tag :dsl_negative
    test "one_of on a non-atom fact" do
      output =
        compile_dsl("""
        defmodule Bad.OneOfType do
          use AshRules

          fact_schema do
            fact :flag, :boolean, one_of: [true]
          end

          rule "r", id: "x.r", severity: :low do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "fact with type :boolean declares one_of [true]"
      assert output =~ "declare the fact as `:atom` or drop the one_of"
    end

    @tag :dsl_negative
    test "duplicate fact declaration" do
      output =
        compile_dsl("""
        defmodule Bad.DuplicateFact do
          use AshRules

          fact_schema do
            fact :flag, :boolean
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :low do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "fact :flag is declared more than once"
    end

    @tag :dsl_negative
    test "duplicate combining declaration" do
      output =
        compile_dsl("""
        defmodule Bad.DuplicateCombining do
          use AshRules

          combining :deny_overrides
          combining :permit_overrides

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :low do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)

      assert output =~ "combining"
    end

    test "unknown combining algorithm fails at expansion" do
      assert_raise Spark.Error.DslError, ~r/algorithm/, fn ->
        compile_dsl("""
        defmodule Bad.Algorithm do
          use AshRules

          combining :bogus

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :low do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)
      end
    end

    test "unknown rule option fails at expansion" do
      assert_raise ArgumentError, ~r/unknown rule option/, fn ->
        compile_dsl("""
        defmodule Bad.RuleOption do
          use AshRules

          fact_schema do
            fact :flag, :boolean
          end

          rule "r", id: "x.r", severity: :low, nonsense: 1 do
            outcome :noncompliant, gap: "x.r"
          end
        end
        """)
      end
    end
  end
end
