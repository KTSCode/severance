defmodule Severance.PhaseTest do
  use ExUnit.Case, async: true

  alias Severance.Phase

  doctest Phase

  describe "phase_for_remaining/1" do
    test "gentle above 15 minutes" do
      assert Phase.phase_for_remaining(30) == :gentle
      assert Phase.phase_for_remaining(16) == :gentle
    end

    test "aggressive between 6 and 15 minutes" do
      assert Phase.phase_for_remaining(15) == :aggressive
      assert Phase.phase_for_remaining(6) == :aggressive
    end

    test "final between 1 and 5 minutes" do
      assert Phase.phase_for_remaining(5) == :final
      assert Phase.phase_for_remaining(1) == :final
    end

    test "shutdown at or below 0 minutes" do
      assert Phase.phase_for_remaining(0) == :shutdown
      assert Phase.phase_for_remaining(-1) == :shutdown
    end
  end

  describe "interval_ms/1" do
    test "returns the tick cadence for escalation phases" do
      assert Phase.interval_ms(:gentle) == 5 * 60 * 1000
      assert Phase.interval_ms(:aggressive) == 2 * 60 * 1000
      assert Phase.interval_ms(:final) == 60 * 1000
    end

    test "returns nil for non-escalation phases" do
      assert Phase.interval_ms(:waiting) == nil
      assert Phase.interval_ms(:shutdown) == nil
      assert Phase.interval_ms(:done) == nil
    end
  end

  describe "sound/1" do
    test "returns the notification sound for escalation phases" do
      assert Phase.sound(:gentle) == "Tink"
      assert Phase.sound(:aggressive) == "Funk"
      assert Phase.sound(:final) == "Basso"
    end

    test "returns nil for non-escalation phases" do
      assert Phase.sound(:waiting) == nil
      assert Phase.sound(:shutdown) == nil
      assert Phase.sound(:done) == nil
    end
  end

  describe "color/2 with default palette" do
    test "waiting and gentle share the first color" do
      assert Phase.color(:waiting) == "colour51"
      assert Phase.color(:gentle) == "colour51"
    end

    test "aggressive uses the second color" do
      assert Phase.color(:aggressive) == "colour226"
    end

    test "final, shutdown, and done use the third color" do
      assert Phase.color(:final) == "colour196"
      assert Phase.color(:shutdown) == "colour196"
      assert Phase.color(:done) == "colour196"
    end
  end

  describe "color/2 with custom palette" do
    test "maps each phase to its palette position" do
      assert Phase.color(:waiting, ["a", "b", "c"]) == "a"
      assert Phase.color(:aggressive, ["a", "b", "c"]) == "b"
      assert Phase.color(:final, ["a", "b", "c"]) == "c"
    end
  end

  describe "blink?/1" do
    test "aggressive and final blink" do
      assert Phase.blink?(:aggressive)
      assert Phase.blink?(:final)
    end

    test "other phases do not blink" do
      refute Phase.blink?(:waiting)
      refute Phase.blink?(:gentle)
      refute Phase.blink?(:shutdown)
      refute Phase.blink?(:done)
    end
  end

  describe "default_palette/0" do
    test "returns the three-color tmux palette" do
      assert Phase.default_palette() == ["colour51", "colour226", "colour196"]
    end
  end
end
