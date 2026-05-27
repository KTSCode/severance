defmodule Severance.StatusPublisher.Tmux.FormatTest do
  use ExUnit.Case, async: true

  alias Severance.StatusPublisher.Tmux.Format

  describe "color_for_phase/2 with default palette" do
    test "waiting returns first color" do
      assert Format.color_for_phase(:waiting) == "colour51"
    end

    test "gentle returns first color" do
      assert Format.color_for_phase(:gentle) == "colour51"
    end

    test "aggressive returns second color" do
      assert Format.color_for_phase(:aggressive) == "colour226"
    end

    test "final returns third color" do
      assert Format.color_for_phase(:final) == "colour196"
    end

    test "shutdown returns third color" do
      assert Format.color_for_phase(:shutdown) == "colour196"
    end

    test "done returns third color" do
      assert Format.color_for_phase(:done) == "colour196"
    end
  end

  describe "color_for_phase/2 with custom palette" do
    test "uses first element for waiting" do
      assert Format.color_for_phase(:waiting, ["a", "b", "c"]) == "a"
    end

    test "uses second element for aggressive" do
      assert Format.color_for_phase(:aggressive, ["a", "b", "c"]) == "b"
    end

    test "uses third element for final" do
      assert Format.color_for_phase(:final, ["a", "b", "c"]) == "c"
    end
  end

  describe "blink_for_phase/1" do
    test "aggressive blinks" do
      assert Format.blink_for_phase(:aggressive) == ",blink"
    end

    test "final blinks" do
      assert Format.blink_for_phase(:final) == ",blink"
    end

    test "waiting does not blink" do
      assert Format.blink_for_phase(:waiting) == ""
    end

    test "gentle does not blink" do
      assert Format.blink_for_phase(:gentle) == ""
    end

    test "done does not blink" do
      assert Format.blink_for_phase(:done) == ""
    end

    test "shutdown does not blink" do
      assert Format.blink_for_phase(:shutdown) == ""
    end
  end
end
