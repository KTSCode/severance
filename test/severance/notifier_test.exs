defmodule Severance.NotifierTest do
  use ExUnit.Case, async: true

  alias Severance.Notifier

  describe "phase_sound/1" do
    test "returns Tink for gentle phase" do
      assert Notifier.phase_sound(:gentle) == "Tink"
    end

    test "returns Funk for aggressive phase" do
      assert Notifier.phase_sound(:aggressive) == "Funk"
    end

    test "returns Basso for final phase" do
      assert Notifier.phase_sound(:final) == "Basso"
    end

    test "returns Basso for overtime phase" do
      assert Notifier.phase_sound(:overtime) == "Basso"
    end
  end

  describe "countdown_message/2" do
    test "severance mode warns about shutdown" do
      assert Notifier.countdown_message(15, :severance) ==
               {"Shutdown in 15m", "Your computer WILL shut down. Push your work."}
    end

    test "overtime mode warns without shutdown threat" do
      assert Notifier.countdown_message(15, :overtime) ==
               {"Shutdown in 15m",
                "Your planned end of day is coming up. Push your work and call it quits."}
    end

    test "uses urgent language at 5 minutes" do
      {title, _body} = Notifier.countdown_message(5, :severance)
      assert title == "SHUTDOWN IN 5m"
    end

    test "uses urgent language at 1 minute" do
      {title, body} = Notifier.countdown_message(1, :severance)
      assert title == "FINAL WARNING"
      assert body =~ "1 minute"
    end

    test "overtime 1-minute message uses correct grammar" do
      {_title, body} = Notifier.countdown_message(1, :overtime)
      assert body =~ "to decide to be"
      refute body =~ "decided"
    end
  end

  describe "send_stale_pane/2" do
    test "stale pane message uses correct grammar" do
      source = File.read!("lib/severance/notifier.ex")
      assert source =~ "Save your work"
      refute source =~ "Save you work"
    end

    test "interpolates threshold minutes in message" do
      source = File.read!("lib/severance/notifier.ex")
      assert source =~ "No activity in \#{threshold_minutes}m"
    end
  end
end
