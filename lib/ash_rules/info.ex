# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Info do
  @moduledoc """
  Introspection for compiled rule set modules.
  """

  alias AshRules.Ir.Bundle

  @doc "The compiled bundle of a rule set module, or `{:error, :no_bundle}`."
  @spec bundle(module()) :: {:ok, Bundle.t()} | {:error, :no_bundle}
  def bundle(module) when is_atom(module) do
    if function_exported?(module, :persisted, 2) do
      case Spark.Dsl.Extension.get_persisted(module, :bundle) do
        %Bundle{} = bundle -> {:ok, bundle}
        _other -> {:error, :no_bundle}
      end
    else
      {:error, :no_bundle}
    end
  end

  @doc "Like `bundle/1`, but raises on a module that is not a rule set."
  @spec bundle!(module()) :: Bundle.t()
  def bundle!(module) when is_atom(module) do
    case bundle(module) do
      {:ok, bundle} ->
        bundle

      {:error, :no_bundle} ->
        raise ArgumentError,
              "#{inspect(module)} is not an AshRules module. " <>
                "Add `use AshRules` to it first"
    end
  end

  @doc "The compiled rules of a rule set module, in id order."
  @spec rules(module()) :: [AshRules.Ir.Rule.t()]
  def rules(module), do: bundle!(module).rules

  @doc "The fact schema of a rule set module."
  @spec fact_schema(module()) :: AshRules.Ir.FactSchema.t()
  def fact_schema(module), do: bundle!(module).fact_schema

  @doc "The combining algorithm declared by a rule set module."
  @spec combining(module()) :: AshRules.Combining.algorithm()
  def combining(module), do: bundle!(module).combining
end
