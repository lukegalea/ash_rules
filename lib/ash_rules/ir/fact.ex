# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.Ir.Fact do
  @moduledoc """
  One entry of a fact schema: what a predicate means, what shape its value has,
  and what absence of the fact means.

  * `type` — `:atom`, `:boolean`, `:string`, `:integer`, `:float`, `:number`,
    `:date`, `:utc_datetime` or `:any`. Fact values are type-checked against it
    at evaluation time and rule predicates against it at compile time.
  * `one_of` — for `:atom` facts, the closed vocabulary of allowed values.
  * `cardinality` — `:one` (the only supported value in 0.1): one value per
    subject-predicate pair. Enforcing it is the fact producer's duty; the
    schema declares it so consumers know what to expect.
  * `missing` — absence semantics:
      * `:false` — absence counts as the value `false`, and the absence is
        reported in the result's missing facts (an auditor wants to know that
        "no data" became "false").
      * `:unknown` — absence makes every rule probing the fact `:unknown`;
        never silently false.
      * `:no_fact` — absence is an expected, meaningful state: probes behave
        like `:false` but the absence is not reported as a data gap.
  * `sensitive?` — the value is PII or a secret; hosts should treat it
    accordingly when persisting results.
  * `tenant_scoped?` — values differ per tenant; bundles must not hard-code
    them.
  * `dependencies` — other predicates expected alongside this one.
  """

  defstruct [
    :name,
    :type,
    :one_of,
    :cardinality,
    :missing,
    :description,
    :source,
    :dependencies,
    :sensitive?,
    :tenant_scoped?,
    __spark_metadata__: nil
  ]

  @type value_type() ::
          :atom
          | :boolean
          | :string
          | :integer
          | :float
          | :number
          | :date
          | :utc_datetime
          | :any

  @type missing_semantics() :: false | :unknown | :no_fact

  @type cardinality() :: :one

  @type t() :: %__MODULE__{
          name: atom(),
          type: value_type(),
          one_of: [atom()] | nil,
          cardinality: cardinality(),
          missing: missing_semantics(),
          description: String.t() | nil,
          source: String.t() | nil,
          dependencies: [atom()],
          sensitive?: boolean(),
          tenant_scoped?: boolean()
        }

  @types [:atom, :boolean, :string, :integer, :float, :number, :date, :utc_datetime, :any]
  @missing_values [false, :unknown, :no_fact]

  @doc "The supported value types."
  @spec types() :: [value_type(), ...]
  def types, do: @types

  @doc "The supported absence semantics."
  @spec missing_values() :: [missing_semantics(), ...]
  def missing_values, do: @missing_values

  @cardinalities [:one]

  @doc "The supported cardinalities."
  @spec cardinalities() :: [cardinality(), ...]
  def cardinalities, do: @cardinalities

  @doc "Builds a fact entry with the house defaults (`missing: :false`)."
  @spec new(atom(), value_type(), keyword()) :: t()
  def new(name, type, opts \\ []) when is_atom(name) and type in @types do
    %__MODULE__{
      name: name,
      type: type,
      one_of: one_of(opts[:one_of]),
      cardinality: Keyword.get(opts, :cardinality, :one),
      missing: Keyword.get(opts, :missing, false),
      description: Keyword.get(opts, :description),
      source: Keyword.get(opts, :source),
      dependencies: List.wrap(Keyword.get(opts, :dependencies, [])),
      sensitive?: Keyword.get(opts, :sensitive?, false),
      tenant_scoped?: Keyword.get(opts, :tenant_scoped?, false)
    }
  end

  @doc "True if the value is a valid runtime value for this fact."
  @spec valid_value?(t(), term()) :: boolean()
  def valid_value?(%__MODULE__{type: type, one_of: one_of}, value) do
    type_ok?(type, value) and one_of_ok?(one_of, value)
  end

  @doc "True if the literal is a valid *compile-time* predicate value for this fact."
  @spec valid_literal?(t(), term()) :: boolean()
  def valid_literal?(%__MODULE__{} = fact, literal) do
    valid_value?(fact, literal)
  end

  @doc """
  Converts a decoded JSON value to the fact's runtime type.

  `:atom` values become atoms (admission is a trusted control-plane boundary:
  the schema's vocabulary is size-bounded and signed via the content hash).
  `:date`/`:utc_datetime` values are parsed from ISO 8601. Anything already in
  shape passes through — the verifiers refuse what does not type-check.
  """
  @spec decode_value(value_type(), term()) :: {:ok, term()} | {:error, String.t()}
  def decode_value(:atom, value) when is_binary(value), do: {:ok, String.to_atom(value)}

  def decode_value(:date, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "not an ISO 8601 date: #{inspect(value)}"}
    end
  end

  def decode_value(:utc_datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, "not an ISO 8601 datetime: #{inspect(value)}"}
    end
  end

  def decode_value(_type, value), do: {:ok, value}

  @doc "The JSON object form, for the codec and canonical hashing."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = fact) do
    base = %{
      "name" => Atom.to_string(fact.name),
      "type" => Atom.to_string(fact.type),
      "cardinality" => Atom.to_string(fact.cardinality),
      "missing" => Atom.to_string(fact.missing),
      "dependencies" => Enum.map(fact.dependencies, &Atom.to_string/1),
      "sensitive?" => fact.sensitive?,
      "tenant_scoped?" => fact.tenant_scoped?
    }

    base
    |> put_if("one_of", fact.one_of && Enum.map(fact.one_of, &Atom.to_string/1))
    |> put_if("description", fact.description)
    |> put_if("source", fact.source)
  end

  @doc "Decodes the JSON object form, validating type and semantics names."
  @spec from_json(map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"name" => name, "type" => type} = json) when is_binary(name) do
    with :ok <- validate_member("type", type, @types),
         :ok <- validate_member("cardinality", json["cardinality"] || "one", @cardinalities),
         :ok <- validate_member("missing", json["missing"] || "false", @missing_values),
         :ok <- validate_one_of(json["one_of"]),
         :ok <- validate_names("dependencies", json["dependencies"] || []) do
      {:ok,
       %__MODULE__{
         name: String.to_atom(name),
         type: String.to_atom(type),
         one_of: json["one_of"] && Enum.map(json["one_of"], &String.to_atom/1),
         cardinality: String.to_atom(json["cardinality"] || "one"),
         missing: String.to_atom(json["missing"] || "false"),
         description: json["description"],
         source: json["source"],
         dependencies: Enum.map(json["dependencies"] || [], &String.to_atom/1),
         sensitive?: truthy(json["sensitive?"]),
         tenant_scoped?: truthy(json["tenant_scoped?"])
       }}
    end
  end

  def from_json(_), do: {:error, "a fact schema entry must have name and type"}

  defp one_of(nil), do: nil
  defp one_of(values), do: List.wrap(values)

  defp type_ok?(:atom, value), do: is_atom(value) and not is_boolean(value)
  defp type_ok?(:boolean, value), do: is_boolean(value)
  defp type_ok?(:string, value), do: is_binary(value)
  defp type_ok?(:integer, value), do: is_integer(value)
  defp type_ok?(:float, value), do: is_float(value)
  defp type_ok?(:number, value), do: is_number(value)
  defp type_ok?(:date, value), do: is_struct(value, Date)
  defp type_ok?(:utc_datetime, value), do: is_struct(value, DateTime)
  defp type_ok?(:any, _value), do: true

  defp one_of_ok?(nil, _value), do: true
  defp one_of_ok?(one_of, value), do: Enum.member?(one_of, value)

  defp validate_member(field, value, values) when is_atom(value) do
    if value in values do
      :ok
    else
      {:error, "#{field} #{inspect(value)} is not one of #{inspect(values)}"}
    end
  end

  defp validate_member(field, value, values) when is_binary(value) do
    if value in Enum.map(values, &Atom.to_string/1) do
      :ok
    else
      {:error, "#{field} #{inspect(value)} is not one of #{inspect(values)}"}
    end
  end

  defp validate_member(field, value, values),
    do: {:error, "#{field} #{inspect(value)} is not one of #{inspect(values)}"}

  defp validate_one_of(nil), do: :ok

  defp validate_one_of(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error, "one_of must be a list of atom names"}
    end
  end

  defp validate_one_of(_), do: {:error, "one_of must be a list of atom names"}

  defp validate_names(_field, names) when is_list(names) do
    if Enum.all?(names, &is_binary/1), do: :ok, else: {:error, "predicate names must be strings"}
  end

  defp validate_names(field, _), do: {:error, "#{field} must be a list of predicate names"}

  defp truthy(nil), do: false
  defp truthy(value), do: value

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
