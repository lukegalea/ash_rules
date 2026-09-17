# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.Var do
  @moduledoc """
  A variable reference inside a rule predicate.

  Variables are how one rule clause talks about the entity another clause
  matched: `has(var(:customer), :kyc, :valid)` binds `:customer` to whatever
  subject satisfied an earlier clause, instead of naming one subject literally.

  A variable binds on its first occurrence in an `has/3` clause and must be
  bound before any `neg/3` clause uses it — enforced at compile time by the DSL
  verifiers and again at admission by `AshRules.Ir.decode/1`. JSON spells it
  `%{"var" => "customer"}`.
  """

  defstruct [:name]

  @type t() :: %__MODULE__{name: atom()}

  @doc "Builds a variable reference. The name must already be an atom."
  @spec new(atom()) :: t()
  def new(name) when is_atom(name), do: %__MODULE__{name: name}
end
