defmodule Severance.ApplicationTest do
  use ExUnit.Case, async: true

  alias Severance.Application

  describe "cli_argv/0" do
    test "returns System.argv() when Burrito is not loaded" do
      assert Application.cli_argv() == System.argv()
    end
  end

  describe "start_daemon/0" do
    test "starts the supervisor tree" do
      # The application is already started by ExUnit, so we verify
      # the supervisor is running
      assert Process.whereis(Severance.Supervisor) != nil
    end
  end
end
