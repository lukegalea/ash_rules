# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshRules.StandingsTest do
  @moduledoc """
  The standing-query event contract, worked example by example: the full
  three-by-three transition table (unknown never folded into `in` or `out`),
  the missing-partition rule, dispatch behaviour conformance, and the two
  reference consumer patterns (BPMN-facing, notifications-facing). The
  randomized proof that diffs equal per-subject partition changes lives in
  `AshRules.StandingsPropertyTest`.
  """

  use ExUnit.Case, async: true

  alias AshRules.Evaluator.Set
  alias AshRules.Evaluator.Set.Membership
  alias AshRules.Standings
  alias AshRules.Standings.Event
  alias AshRules.Standings.Query
  alias AshRules.TestSupport.RuleSets

  @schema RuleSets.Property.__bundle__().fact_schema

  defp membership(in_subjects, out_subjects, unknown_subjects) do
    %Membership{in: in_subjects, out: out_subjects, unknown: unknown_subjects}
  end

  defp single_event!(before, after_partition) do
    events = Standings.diff(before, after_partition)
    assert length(events) == 1, "expected one event, got #{inspect(events)}"
    hd(events)
  end

  describe "the transition table" do
    test "in -> out is :left" do
      event = single_event!(membership([:s], [], []), membership([], [:s], []))

      assert %Event{kind: :left, subject: :s, from: :in, to: :out} == event
    end

    test "in -> unknown is :became_unknown, never :left" do
      event = single_event!(membership([:s], [], []), membership([], [], [:s]))

      assert %Event{kind: :became_unknown, subject: :s, from: :in, to: :unknown} == event
    end

    test "out -> in is :entered" do
      event = single_event!(membership([], [:s], []), membership([:s], [], []))

      assert %Event{kind: :entered, subject: :s, from: :out, to: :in} == event
    end

    test "out -> unknown is :became_unknown" do
      event = single_event!(membership([], [:s], []), membership([], [], [:s]))

      assert %Event{kind: :became_unknown, subject: :s, from: :out, to: :unknown} == event
    end

    test "unknown -> in is :entered, carrying where it came from" do
      event = single_event!(membership([], [], [:s]), membership([:s], [], []))

      assert %Event{kind: :entered, subject: :s, from: :unknown, to: :in} == event
    end

    test "unknown -> out is :resolved_out — not :left (never in), not silence (not out)" do
      event = single_event!(membership([], [], [:s]), membership([], [:s], []))

      assert %Event{kind: :resolved_out, subject: :s, from: :unknown, to: :out} == event
    end

    test "unchanged verdicts produce no event" do
      assert [] == Standings.diff(membership([:s], [], []), membership([:s], [], []))
      assert [] == Standings.diff(membership([], [:s], []), membership([], [:s], []))
      assert [] == Standings.diff(membership([], [], [:s]), membership([], [], [:s]))
    end
  end

  describe "the missing-partition rule" do
    test "a subject absent from the after partition degrades to :became_unknown" do
      # The fact source shrank: no deciding fact is exactly the unknown
      # partition's meaning, so this is never :left.
      event = single_event!(membership([:s], [], []), membership([], [], []))

      assert %Event{kind: :became_unknown, subject: :s, from: :in, to: :unknown} == event
    end

    test "a subject absent from the before partition enters from unknown" do
      event = single_event!(membership([], [], []), membership([:s], [], []))

      assert %Event{kind: :entered, subject: :s, from: :unknown, to: :in} == event
    end

    test "two empty partitions diff to nothing" do
      assert [] == Standings.diff(membership([], [], []), membership([], [], []))
    end
  end

  test "a mixed diff yields one event per changed subject, sorted by subject" do
    before = membership([:s1, :s3], [:s2], [:s4, :s5])
    after_partition = membership([:s2, :s4], [:s1], [:s3, :s5])

    events = Standings.diff(before, after_partition)

    assert [
             %Event{subject: :s1},
             %Event{subject: :s2},
             %Event{subject: :s3},
             %Event{subject: :s4}
           ] =
             events

    assert [
             %{kind: :left, from: :in, to: :out},
             %{kind: :entered, from: :out, to: :in},
             %{kind: :became_unknown, from: :in, to: :unknown},
             %{kind: :entered, from: :unknown, to: :in}
           ] ==
             Enum.map(events, &Map.take(&1, [:kind, :from, :to]))

    # s5 stayed unknown: no event.
    refute Enum.any?(events, &(&1.subject == :s5))
  end

  describe "query identity" do
    defp predicates,
      do: [AshRules.Ir.Predicate.new(:has, AshRules.Ir.Var.new(:s), :p_d, true)]

    test "the same expression yields the same hash" do
      {:ok, one} = Standings.query(@schema, predicates())
      {:ok, two} = Standings.query(@schema, predicates())

      assert one.hash == two.hash
      assert String.valid?(one.hash) and byte_size(one.hash) == 64
    end

    test "a different expression yields a different hash" do
      {:ok, one} = Standings.query(@schema, predicates())

      {:ok, two} =
        Standings.query(@schema, [
          AshRules.Ir.Predicate.new(:has, AshRules.Ir.Var.new(:s), :p_d, false)
        ])

      refute one.hash == two.hash
    end

    test "opts carry the name and the hash override" do
      bundle_hash = RuleSets.Property.__bundle__().content_hash

      {:ok, query} =
        Standings.query(@schema, predicates(), name: "vendor roof work", hash: bundle_hash)

      assert %Query{name: "vendor roof work", hash: ^bundle_hash} = query
    end

    test "compilation refusals come back unchanged" do
      bad = [
        AshRules.Ir.Predicate.new(:has, AshRules.Ir.Var.new(:a), :p_d, true),
        AshRules.Ir.Predicate.new(:has, AshRules.Ir.Var.new(:b), :p_d, true)
      ]

      assert {:error, message} = Standings.query(@schema, bad)
      assert message =~ "one subject variable"
    end
  end

  describe "evaluate" do
    test "derives the partition through the set evaluator" do
      {:ok, query} = Standings.query(@schema, predicates())

      assert {:ok, %Membership{in: [:s1], out: [], unknown: []}} =
               Standings.evaluate(query, [{:s1, :p_d, true}], [])
    end
  end

  describe "dispatch" do
    defmodule Recorder do
      @moduledoc "A dispatcher that records the streams it receives."
      @behaviour Standings.Dispatcher

      def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
      def calls, do: Agent.get(__MODULE__, & &1)

      @impl true
      def handle_events(query, events, opts) do
        Agent.update(__MODULE__, &[{query, events, opts} | &1])
        :ok
      end
    end

    setup do
      {:ok, _} = Recorder.start_link()
      :ok
    end

    test "the dispatcher receives the query, the events, and the opts" do
      {:ok, query} = Standings.query(@schema, predicates(), name: "roof work")

      events = [
        %Event{kind: :entered, subject: :s1, from: :unknown, to: :in}
      ]

      assert :ok == Standings.dispatch(query, events, Recorder, tenant: :t1)

      assert [{^query, ^events, [tenant: :t1]}] = Recorder.calls()
    end

    test "a module without handle_events/3 is refused" do
      {:ok, query} = Standings.query(@schema, predicates())

      assert {:error, message} = Standings.dispatch(query, [], String)
      assert message =~ "does not implement AshRules.Standings.Dispatcher"
      assert message =~ "handle_events/3"
    end
  end

  describe "run — the standing-query round trip" do
    defmodule RunRecorder do
      @moduledoc false
      @behaviour Standings.Dispatcher

      def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
      def calls, do: Agent.get(__MODULE__, & &1)

      @impl true
      def handle_events(query, events, opts) do
        Agent.update(__MODULE__, &[{query, events, opts} | &1])
        :ok
      end
    end

    setup do
      {:ok, _} = RunRecorder.start_link()
      :ok
    end

    test "evaluates both fact sources, diffs, and dispatches the stream" do
      {:ok, query} = Standings.query(@schema, predicates())

      facts_before = [{:s1, :p_d, false}, {:s2, :p_d, false}]
      facts_after = [{:s1, :p_d, true}]

      assert {:ok, events} =
               Standings.run(query, facts_before, facts_after, RunRecorder, tenant: :t1)

      assert [
               %Event{kind: :entered, subject: :s1, from: :out, to: :in},
               %Event{kind: :became_unknown, subject: :s2, from: :out, to: :unknown}
             ] == events

      assert [{^query, ^events, [tenant: :t1]}] = RunRecorder.calls()
    end

    test "an empty diff is not dispatched" do
      {:ok, query} = Standings.query(@schema, predicates())
      facts = [{:s1, :p_d, true}]

      assert {:ok, []} = Standings.run(query, facts, facts, RunRecorder)
      assert [] == RunRecorder.calls()
    end

    test "evaluation errors propagate" do
      {:ok, query} = Standings.query(@schema, predicates())

      assert {:error, message} =
               Standings.run(query, [{:s1, :not_in_schema, true}], [], RunRecorder)

      assert message =~ "not in the fact schema"
    end
  end

  describe "reference consumers" do
    defmodule BpmnStyleDispatcher do
      @moduledoc """
      The BPMN-facing reference consumer, in miniature.

      Models the ash_enterprise pattern (subscription -> dispatch row ->
      instance start / signal): every event becomes one persisted dispatch
      row *in the same transaction as* the message it delivers, so "why did
      this process start" has a row; the message name derives from the
      standing query's hash and the event kind, so a subscription can catch
      `ash_rules/<hash>/<kind>` as a message start or an intermediate
      message. `became_unknown` with `from: :in` signals the *running*
      instance (its premise lapsed); `left` closes it. The real host writes
      these rows with its repo in one transaction — the shape is what this
      exemplar pins.
      """

      @behaviour Standings.Dispatcher

      def start_link, do: Agent.start_link(fn -> %{rows: [], messages: []} end, name: __MODULE__)

      def state, do: Agent.get(__MODULE__, & &1)

      @impl true
      def handle_events(query, events, opts) do
        Enum.each(events, fn event ->
          # The dispatch row: append-only, one per (query, subject, kind) —
          # in the real host, written in the same transaction as the
          # instance start or signal it causes.
          row = %{query_hash: query.hash, event: event, opts: opts}

          message =
            {:message, "ash_rules/#{query.hash}/#{event.kind}", event.subject,
             %{from: event.from, to: event.to}}

          case event do
            %Event{kind: :entered} ->
              Agent.update(__MODULE__, fn state ->
                %{state | rows: [row | state.rows], messages: [:start_instance | state.messages]}
              end)

            %Event{kind: :became_unknown, from: :in} ->
              Agent.update(__MODULE__, fn state ->
                %{state | rows: [row | state.rows], messages: [:signal_lapsed | state.messages]}
              end)

            %Event{kind: :left} ->
              Agent.update(__MODULE__, fn state ->
                %{state | rows: [row | state.rows], messages: [:signal_closed | state.messages]}
              end)

            # resolved_out: nothing is running for a subject that was never
            # in — retire the assess-side unknown, start nothing.
            %Event{kind: :resolved_out} ->
              Agent.update(__MODULE__, fn state -> %{state | rows: [row | state.rows]} end)
          end

          message
        end)

        :ok
      end
    end

    defmodule NotificationStyleDispatcher do
      @moduledoc """
      The notifications-facing reference consumer, in miniature.

      `entered` notifies (the subject now qualifies); `left` notifies the
      revocation; `became_unknown` opens an assess task instead of notifying
      — an undecidable membership is work, not a verdict, and it is never
      rendered as either `in` or `out`; `resolved_out` needs nothing.
      """

      @behaviour Standings.Dispatcher

      def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

      def notifications, do: Agent.get(__MODULE__, &Enum.reverse(&1))

      @impl true
      def handle_events(query, events, _opts) do
        Enum.each(events, fn
          %Event{kind: :entered, subject: subject} ->
            Agent.update(__MODULE__, &[{:notify, subject, query.hash} | &1])

          %Event{kind: :left, subject: subject} ->
            Agent.update(__MODULE__, &[{:notify_revoked, subject, query.hash} | &1])

          %Event{kind: :became_unknown, subject: subject} ->
            Agent.update(__MODULE__, &[{:open_assess_task, subject, query.hash} | &1])

          %Event{kind: :resolved_out, subject: _subject} ->
            :ok
        end)

        :ok
      end
    end

    setup do
      {:ok, _} = BpmnStyleDispatcher.start_link()
      {:ok, _} = NotificationStyleDispatcher.start_link()
      :ok
    end

    test "a BPMN-facing dispatcher starts and signals per the transition" do
      {:ok, query} = Standings.query(@schema, predicates())

      events = [
        %Event{kind: :entered, subject: :s1, from: :out, to: :in},
        %Event{kind: :became_unknown, subject: :s2, from: :in, to: :unknown},
        %Event{kind: :left, subject: :s3, from: :in, to: :out},
        %Event{kind: :resolved_out, subject: :s4, from: :unknown, to: :out}
      ]

      assert :ok = Standings.dispatch(query, events, BpmnStyleDispatcher)

      state = BpmnStyleDispatcher.state()
      # Dispatch rows for every event — the audit answer to "why did this
      # process start"; messages only for the in-set lifecycle.
      assert length(state.rows) == 4
      assert state.messages == [:signal_closed, :signal_lapsed, :start_instance]
    end

    test "a notifications-facing dispatcher notifies on the in-set and tasks on unknown" do
      {:ok, query} = Standings.query(@schema, predicates())

      events = [
        %Event{kind: :entered, subject: :s1, from: :out, to: :in},
        %Event{kind: :became_unknown, subject: :s2, from: :in, to: :unknown},
        %Event{kind: :left, subject: :s3, from: :in, to: :out},
        %Event{kind: :resolved_out, subject: :s4, from: :unknown, to: :out}
      ]

      assert :ok = Standings.dispatch(query, events, NotificationStyleDispatcher)

      assert [
               {:notify, :s1, query.hash},
               {:open_assess_task, :s2, query.hash},
               {:notify_revoked, :s3, query.hash}
             ] == NotificationStyleDispatcher.notifications()
    end
  end
end
