# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.Predicates do
  @moduledoc """
  The predicate builders and clause shorthands available inside `rule` bodies.

  * `has(subject, predicate, value)` — the fact `{subject, predicate, value}`
    must exist. A `%AshRules.Ir.Var{}` from `var/1` in the subject or value
    position binds on first match and unifies thereafter.
  * `neg(subject, predicate, value)` — the fact must not exist. Variables in a
    `neg` must already be bound (absence cannot bind).
  * `var(name)` — a variable reference.

  `when_requires/2..16` and `fails_when/2..16` are the clause shorthands from
  the rule grammar: each expands to the per-predicate entities under
  `applicability` and `failure_conditions` respectively.
  """

  alias AshRules.Ir.Predicate
  alias AshRules.Ir.Var

  @doc "Requires the fact `{subject, predicate, value}` to exist."
  @spec has(term() | Var.t(), atom(), term() | Var.t()) :: Predicate.t()
  def has(subject, name, value), do: Predicate.new(:has, subject, name, value)

  @doc "Requires the fact `{subject, predicate, value}` to be absent."
  @spec neg(term() | Var.t(), atom(), term() | Var.t()) :: Predicate.t()
  def neg(subject, name, value), do: Predicate.new(:neg, subject, name, value)

  @doc "Declares a variable reference for use in `has/3` and `neg/3`."
  @spec var(atom()) :: Var.t()
  def var(name) when is_atom(name), do: Var.new(name)

  for arity <- 0..16 do
    args = Macro.generate_arguments(arity, __MODULE__)

    defmacro when_requires(unquote_splicing(args)) do
      expand(:requires, unquote(args))
    end

    defmacro fails_when(unquote_splicing(args)) do
      expand(:fails, unquote(args))
    end
  end

  defp expand(clause, predicates) do
    predicates = List.wrap(predicates)

    quote do
      (unquote_splicing(
         for predicate <- predicates do
           quote do
             unquote(clause)(unquote(predicate))
           end
         end
       ))
    end
  end
end
