# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Dsl.Verifiers.VerifyFactSchema do
  @moduledoc false

  # Schema-level refusals: duplicate fact names, `one_of` on non-atom facts,
  # and empty `one_of` lists. Value typing against rules is handled by
  # `AshRules.Verifier` in `VerifyRules`.

  use Spark.Dsl.Verifier

  alias AshRules.Ir.Fact
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:fact_schema])
    |> Enum.reduce({%{}, []}, fn %Fact{} = fact, {seen, errors} ->
      errors =
        errors ++
          duplicate_error(fact, seen) ++
          one_of_type_error(fact) ++ one_of_empty_error(fact)

      {Map.put(seen, fact.name, true), errors}
    end)
    |> elem(1)
    |> raise_first(dsl_state, [:fact_schema])
  end

  defp duplicate_error(fact, seen) do
    if Map.has_key?(seen, fact.name) do
      [
        "fact #{inspect(fact.name)} is declared more than once. " <>
          "Remove the duplicate declaration — one fact, one schema entry"
      ]
    else
      []
    end
  end

  defp one_of_type_error(%Fact{type: type, one_of: one_of}) do
    if one_of != nil and type != :atom do
      [
        "fact with type #{inspect(type)} declares one_of #{inspect(one_of)}. " <>
          "one_of constrains `:atom` facts — declare the fact as `:atom` or drop the one_of"
      ]
    else
      []
    end
  end

  defp one_of_empty_error(%Fact{name: name, one_of: one_of}) do
    if one_of == [] do
      [
        "fact #{inspect(name)} declares an empty one_of. " <>
          "List the allowed values (e.g. `one_of: [:active, :suspended]`) or drop the one_of"
      ]
    else
      []
    end
  end

  defp raise_first([], _dsl_state, _path), do: :ok

  defp raise_first([message | _], dsl_state, path) do
    raise DslError,
      module: Transformer.get_persisted(dsl_state, :module),
      message: message,
      path: path
  end
end
