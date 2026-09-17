# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir do
  @moduledoc """
  The serializable rule IR: rules, fact schemas, bundles as plain data.

  This module is the entry point for the wire codec. The IR exists so that rule
  sets are *data, never quoted AST*: they can be hashed, signed, transmitted to
  a tenant control plane, stored, decoded and evaluated years later without the
  module that compiled them. `AshRules.Ir.decode/1` validates on admission with
  the same verifiers the DSL applies at compile time — there is no `Code.eval`
  on this path and no persisted AST anywhere.

  Supported modules:

    * `AshRules.Ir.Bundle` — the unit of evaluation and of audit
    * `AshRules.Ir.Rule` — one rule
    * `AshRules.Ir.FactSchema` / `AshRules.Ir.Fact` — the fact vocabulary
    * `AshRules.Ir.Predicate` / `AshRules.Ir.Var` — rule clauses
    * `AshRules.Ir.OutcomeDeclaration` — what a firing rule asserts
  """

  alias AshRules.Ir.Bundle

  @doc """
  Encodes a bundle to JSON. The encoding is canonical (sorted structure, no
  volatile data), so `AshRules.Ir.Bundle.content_hash/1` over the same content
  is stable across processes, machines and releases.
  """
  @spec encode(Bundle.t()) :: {:ok, String.t()} | {:error, Jason.EncodeError.t() | Exception.t()}
  def encode(%Bundle{} = bundle), do: Jason.encode(Bundle.to_json(bundle))

  @doc "Like `encode/1`, but raises."
  @spec encode!(Bundle.t()) :: String.t()
  def encode!(%Bundle{} = bundle), do: Jason.encode!(Bundle.to_json(bundle))

  @doc """
  Decodes a JSON bundle document, validating on admission.

  Accepts encoded JSON or an already-decoded map. Every field is validated —
  shapes, outcome and severity domains, predicate types against the fact
  schema, variable binding — and the first semantic refusal is returned as
  `{:error, message}`. Refusals name the failing rule and the fix.
  """
  @spec decode(String.t() | map()) :: {:ok, Bundle.t()} | {:error, String.t() | [String.t()]}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decode(decoded)
      {:error, %Jason.DecodeError{}} -> {:error, "invalid JSON"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, "invalid JSON"}
  end

  def decode(%{} = decoded), do: Bundle.from_json(decoded)
  def decode(_), do: {:error, "a bundle document must be JSON or a map"}

  @doc "Like `decode/1`, but raises on invalid input."
  @spec decode!(String.t() | map()) :: Bundle.t()
  def decode!(json) do
    case decode(json) do
      {:ok, bundle} ->
        bundle

      {:error, errors} ->
        raise ArgumentError, "invalid bundle: " <> (List.wrap(errors) |> Enum.join("; "))
    end
  end

  @doc """
  Strict value equality for fact and predicate values: `===` with no numeric
  type coercion.

  Both evaluators must agree bit-for-bit on matches, and Wongi's alpha network
  keys on strict term identity (`80` and `80.0` index differently), so the
  direct evaluator deliberately does not coerce either. A rule that says `80`
  does not match a fact that says `80.0` — declare the fact type that the rule
  actually writes.
  """
  @spec values_equal?(term(), term()) :: boolean()
  def values_equal?(left, right), do: left === right
end
