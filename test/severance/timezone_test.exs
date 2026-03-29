defmodule Severance.TimezoneTest do
  use ExUnit.Case, async: true

  alias Severance.Timezone

  describe "infer/0" do
    test "returns {:ok, tz} with a valid IANA timezone string" do
      assert {:ok, tz} = Timezone.infer()
      assert is_binary(tz)
      assert String.contains?(tz, "/")
    end

    test "returned timezone is recognized by the time zone database" do
      {:ok, tz} = Timezone.infer()
      assert {:ok, %DateTime{}} = DateTime.now(tz)
    end
  end

  describe "infer_from_localtime/1" do
    test "extracts IANA timezone from macOS symlink target" do
      assert {:ok, "America/Los_Angeles"} =
               Timezone.infer_from_localtime("/var/db/timezone/zoneinfo/America/Los_Angeles")
    end

    test "handles three-part timezone names" do
      assert {:ok, "America/Indiana/Indianapolis"} =
               Timezone.infer_from_localtime(
                 "/var/db/timezone/zoneinfo/America/Indiana/Indianapolis"
               )
    end

    test "handles Linux-style paths" do
      assert {:ok, "Europe/London"} =
               Timezone.infer_from_localtime("/usr/share/zoneinfo/Europe/London")
    end

    test "returns error for paths without zoneinfo" do
      assert {:error, :unrecognized_path} = Timezone.infer_from_localtime("/some/random/path")
    end

    test "returns error for empty string" do
      assert {:error, :unrecognized_path} = Timezone.infer_from_localtime("")
    end
  end
end
