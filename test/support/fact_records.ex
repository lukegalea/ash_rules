# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.TestSupport.FactsDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshRules.TestSupport.FactRecords)
  end
end

defmodule AshRules.TestSupport.FactRecords do
  @moduledoc """
  An ETS-backed fact resource: the record shape `AshRules.Evaluator.Set`
  queries on the resource path.

  This is the host contract, made concrete for tests: a fact table exposes
  the attributes `subject`, `predicate` (the string spelling of the IR
  predicate name) and `value`. A host's production table (S1-24 §7.4:
  `subject_type`, `subject_id`, `predicate`, `value`, admission metadata)
  maps onto the same three columns; its Postgres data layer pushes the
  compiled filters down to SQL the same way this resource's ETS layer does.

  `private? true` gives each test process its own table, so parallel
  property runs never share rows: seed with `seed!/1`, wipe with `wipe!/1`.
  """

  use Ash.Resource,
    domain: AshRules.TestSupport.FactsDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    table(:ash_rules_fact_records)
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:subject, :term, allow_nil?: false, public?: true)
    attribute(:predicate, :string, allow_nil?: false, public?: true)
    attribute(:value, :term, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*])
  end

  @doc "Materializes `{subject, predicate, value}` triples as fact records."
  @spec seed!([AshRules.Facts.triple()]) :: [struct()]
  def seed!(triples) do
    Enum.map(triples, fn {subject, name, value} ->
      Ash.create!(
        Ash.Changeset.for_create(__MODULE__, :create, %{
          subject: subject,
          predicate: Atom.to_string(name),
          value: value
        })
      )
    end)
  end

  @doc "Removes every record from this process's table."
  @spec wipe!() :: :ok
  def wipe! do
    __MODULE__
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!(&1))

    :ok
  end
end
