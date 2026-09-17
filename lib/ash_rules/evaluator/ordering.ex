# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Evaluator.Ordering do
  @moduledoc false

  # Shared deterministic ordering for bindings and findings. Both evaluators
  # sort with the same key so that finding indices, derived facts and message
  # rendering agree bit-for-bit.

  @spec sort_bindings([map()]) :: [map()]
  def sort_bindings(bindings) do
    Enum.sort_by(bindings, fn binding ->
      binding
      |> Enum.sort()
      |> Enum.map(fn {_key, value} -> term_key(value) end)
    end)
  end

  @spec term_key(term()) :: tuple()
  def term_key(value) when is_number(value), do: {0, value}
  def term_key(value) when is_binary(value), do: {1, value}
  def term_key(value) when is_atom(value), do: {2, Atom.to_string(value)}
  def term_key(value), do: {3, inspect(value)}
end
