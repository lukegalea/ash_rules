# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.Predicate do
  @moduledoc """
  One clause of a rule: a ground or partially-variable triple probe.

  `op` is `:has` ("this fact exists") or `:neg` ("this fact does not exist").
  `subject` and `value` may be `%AshRules.Ir.Var{}` references; the predicate
  `name` is always an atom declared in the bundle's fact schema. `:neg` clauses
  may not introduce variables — absence cannot bind — which the verifiers
  enforce.

  JSON spelling:

      %{"op" => "has", "subject" => "customer", "name" => "status", "value" => "active"}
      %{"op" => "neg", "subject" => %{"var" => "account"}, "name" => "frozen", "value" => true}
  """

  alias AshRules.Ir.Var

  defstruct [:op, :subject, :name, :value]

  @type t() :: %__MODULE__{
          op: :has | :neg,
          subject: term() | Var.t(),
          name: atom(),
          value: term() | Var.t()
        }

  @ops [:has, :neg]

  @doc "Builds a predicate. Used by the DSL functions `has/3` and `neg/3`."
  @spec new(:has | :neg, term(), atom(), term()) :: t()
  def new(op, subject, name, value)
      when op in @ops and is_atom(name) do
    %__MODULE__{op: op, subject: subject, name: name, value: value}
  end

  @doc "True if the predicate probes a fully ground triple (no variables)."
  @spec ground?(t()) :: boolean()
  def ground?(%__MODULE__{subject: subject, value: value}) do
    not var?(subject) and not var?(value)
  end

  @doc "True if the term is a variable reference."
  @spec var?(term()) :: boolean()
  def var?(%Var{}), do: true
  def var?(_), do: false

  @doc "Substitutes bound variables using the given binding map."
  @spec resolve(t(), %{atom() => term()}) :: {term(), atom(), term()}
  def resolve(%__MODULE__{subject: s, name: name, value: v}, bindings) do
    {deref(s, bindings), name, deref(v, bindings)}
  end

  @doc "The variable names the predicate would bind (only `:has` binds)."
  @spec binds(t()) :: [atom()]
  def binds(%__MODULE__{op: :has, subject: s, value: v}) do
    [s, v] |> Enum.filter(&var?/1) |> Enum.map(& &1.name)
  end

  def binds(%__MODULE__{op: :neg}), do: []

  @doc "The variable names the predicate reads (bound by an earlier clause)."
  @spec reads(t()) :: [atom()]
  def reads(%__MODULE__{subject: s, value: v}) do
    [s, v] |> Enum.filter(&var?/1) |> Enum.map(& &1.name)
  end

  defp deref(%Var{name: name}, bindings), do: Map.fetch!(bindings, name)
  defp deref(term, _bindings), do: term

  @doc "The JSON object form, for the codec and canonical hashing."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{op: op, subject: s, name: name, value: v}) do
    %{
      "op" => to_string(op),
      "subject" => encode_term(s),
      "name" => to_string(name),
      "value" => encode_term(v)
    }
  end

  @doc "Decodes the JSON object form. `fact_types` maps predicate names to value types for value conversion."
  @spec from_json(map(), %{optional(atom()) => atom()}) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"op" => op, "subject" => s, "name" => name, "value" => v} = _json, fact_types)
      when op in ["has", "neg"] and is_binary(name) do
    with {:ok, subject} <- decode_term(s),
         {:ok, value} <- decode_value(v, fact_types[String.to_atom(name)]) do
      {:ok,
       %__MODULE__{
         op: String.to_existing_atom(op),
         subject: subject,
         name: String.to_atom(name),
         value: value
       }}
    end
  end

  def from_json(_json, _fact_types),
    do: {:error, "a predicate must have op, subject, name and value"}

  @doc "The bare JSON decode, with no value type conversion (subjects stay opaque)."
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(json), do: from_json(json, %{})

  defp encode_term(%Var{name: name}), do: %{"var" => to_string(name)}
  defp encode_term(term), do: term

  defp decode_term(%{"var" => name}) when is_binary(name),
    do: {:ok, Var.new(String.to_atom(name))}

  defp decode_term(term), do: {:ok, term}

  defp decode_value(%{"var" => name} = var, _type) when is_binary(name), do: decode_term(var)
  defp decode_value(value, nil), do: {:ok, value}
  defp decode_value(value, type), do: AshRules.Ir.Fact.decode_value(type, value)
end
