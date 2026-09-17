# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.PredicateRef do
  @moduledoc false

  # DSL-internal wrapper: the `requires`/`fails` entities hold one
  # `AshRules.Ir.Predicate` each; the rule entity's transform unwraps them into
  # plain predicate lists on the IR rule.
  defstruct [:predicate, __spark_metadata__: nil]

  @type t() :: %__MODULE__{predicate: AshRules.Ir.Predicate.t() | nil}
end
