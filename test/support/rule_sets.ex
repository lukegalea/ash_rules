# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.TestSupport.RuleSets.KYC do
  @moduledoc false

  # The golden rule set: the design-doc KYC example plus rules exercising
  # variables, numbers, absence semantics and metadata.

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom,
      one_of: [:active, :suspended],
      description: "Customer lifecycle status"
    )

    fact(:jurisdiction, :atom)

    fact(:has_valid_kyc, :boolean,
      missing: :unknown,
      description: "KYC verification result; no data means we cannot know"
    )

    fact(:reviewed_at, :boolean,
      missing: :no_fact,
      description: "Whether a review happened; absence means not reviewed yet"
    )

    fact(:balance, :integer)
    fact(:owner, :atom)
  end

  rule "suspended customer with non-zero balance is a finding",
    id: "acct.balance_frozen",
    severity: :low,
    message: "account %{account} holds a non-zero balance while suspended",
    controls: ["AC-02"] do
    when_requires(
      has(:customer, :status, :suspended),
      has(var(:account), :owner, :customer)
    )

    fails_when(neg(var(:account), :balance, 0))
    outcome(:noncompliant, gap: "acct.balance")
  end

  rule "active regulated customer requires valid KYC",
    id: "kyc.valid_required",
    severity: :medium,
    remediation_ref: "runbooks/kyc-verification",
    evidence: ["kyc.vendor_result"],
    source: "Policy 4.1" do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :jurisdiction, :regulated)
    )

    fails_when(neg(:customer, :has_valid_kyc, true))
    outcome(:noncompliant, gap: "kyc.valid_required")
  end

  rule "active regulated customer requires a recorded review",
    id: "kyc.review_required",
    severity: :high do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :reviewed_at, true))
    outcome(:noncompliant, gap: "kyc.review")
  end
end

defmodule AshRules.TestSupport.RuleSets.KYCPermitOverrides do
  @moduledoc false

  use AshRules

  combining(:permit_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :suspended])
    fact(:flag, :boolean)
    fact(:checked, :boolean, missing: false)
  end

  rule "flag must be true", id: "flag.required", severity: :low do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :flag, true))
    outcome(:noncompliant, gap: "flag.required")
  end

  rule "checked customers are permitted", id: "checked.ok", severity: :low do
    when_requires(has(:customer, :status, :active))
    fails_when(has(:customer, :checked, true))
    outcome(:noncompliant, gap: "checked.ok")
  end
end

defmodule AshRules.TestSupport.RuleSets.Property do
  @moduledoc false

  # A permissive schema for property-generated fact sets.

  use AshRules

  fact_schema do
    fact(:p_a, :atom, one_of: [:x, :y, :z], missing: false)
    fact(:p_b, :boolean, missing: :unknown)
    fact(:p_c, :integer, missing: :no_fact)
    fact(:p_d, :boolean, missing: false)
    fact(:owner, :atom)
  end

  rule "a with x", id: "prop.a_x", severity: :low do
    when_requires(has(:customer, :p_a, :x))
    fails_when(neg(:customer, :p_b, true))
    outcome(:noncompliant, gap: "prop.a_x")
  end

  rule "linked accounts", id: "prop.linked", severity: :low do
    when_requires(has(var(:acct), :owner, :customer))
    fails_when(neg(var(:acct), :p_d, true))
    outcome(:noncompliant, gap: "prop.linked")
  end

  rule "nonzero c", id: "prop.nonzero", severity: :low do
    when_requires(has(:customer, :p_c, 1))
    fails_when(has(:customer, :p_c, 1))
    outcome(:noncompliant, gap: "prop.nonzero")
  end
end
