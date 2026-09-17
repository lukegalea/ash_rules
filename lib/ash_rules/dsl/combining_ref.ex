# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.CombiningRef do
  @moduledoc false

  # The target of the `combining :algorithm` declaration. The transformer
  # folds it into the bundle; more than one is refused by the section's
  # singleton check.

  defstruct [:algorithm, __spark_metadata__: nil]

  @type t() :: %__MODULE__{algorithm: AshRules.Combining.algorithm() | nil}
end
