# Updater Plist Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `sev update` to replace the correct binary (wrapper, not Burrito extraction) and rewrite the LaunchAgent plist after each update.

**Architecture:** `Init.detect_binary_path/0` gains Burrito-awareness via `Burrito.Util.Args.get_bin_path/0`. `Updater` delegates to Init for path resolution and calls `Init.create_plist/0` after writing the new binary.

**Tech Stack:** Elixir, Burrito, LaunchAgent plist

**Spec:** `docs/specs/2026-04-01-updater-plist-fix-design.md`

---

### Task 1: Fix `Init.detect_binary_path/0` to prefer Burrito wrapper path

**Files:**
- Modify: `lib/severance/init.ex:110-116`
- Test: `test/severance/init_test.exs`

- [ ] **Step 1: Write failing test for Burrito-aware path detection**

Add to `test/severance/init_test.exs` inside the existing `describe "detect_binary_path/0"` block:

```elixir
test "prefers __BURRITO_BIN_PATH when set" do
  original = System.get_env("__BURRITO_BIN_PATH")

  try do
    System.put_env("__BURRITO_BIN_PATH", "/usr/local/bin/sev")
    assert Init.detect_binary_path() == "/usr/local/bin/sev"
  after
    if original, do: System.put_env("__BURRITO_BIN_PATH", original), else: System.delete_env("__BURRITO_BIN_PATH")
  end
end

test "falls back to System.find_executable when not in Burrito" do
  original = System.get_env("__BURRITO_BIN_PATH")

  try do
    System.delete_env("__BURRITO_BIN_PATH")
    path = Init.detect_binary_path()
    assert is_binary(path)
  after
    if original, do: System.put_env("__BURRITO_BIN_PATH", original)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/severance/init_test.exs --trace`
Expected: First test fails — current implementation ignores `__BURRITO_BIN_PATH`.

- [ ] **Step 3: Implement Burrito-aware `detect_binary_path/0`**

Replace `detect_binary_path/0` in `lib/severance/init.ex:110-116` with:

```elixir
@doc """
Detects the path to the `sev` binary.

Prefers the Burrito wrapper path when running inside a Burrito-wrapped
binary. Falls back to `System.find_executable/1` or the mix project
build output path.
"""
@spec detect_binary_path() :: String.t()
def detect_binary_path do
  case Burrito.Util.Args.get_bin_path() do
    path when is_binary(path) -> path
    :not_in_burrito -> System.find_executable("sev") || "#{File.cwd!()}/burrito_out/sev"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/init_test.exs --trace`
Expected: All tests pass.

- [ ] **Step 5: Format and lint**

Run: `mix format lib/severance/init.ex test/severance/init_test.exs && mix credo --strict`

- [ ] **Step 6: Commit**

```bash
git add lib/severance/init.ex test/severance/init_test.exs
git commit -m "Fix detect_binary_path to prefer Burrito wrapper path"
```

---

### Task 2: Make `Updater` delegate to `Init.detect_binary_path/0`

**Files:**
- Modify: `lib/severance/updater.ex:227-230`
- Test: `test/severance/updater_test.exs`

- [ ] **Step 1: Write failing test that verifies updater uses Init's path**

Add to `test/severance/updater_test.exs` inside `describe "run/1"`:

```elixir
test "writes to the Burrito wrapper path when __BURRITO_BIN_PATH is set" do
  tmp_dir =
    Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

  File.mkdir_p!(tmp_dir)
  wrapper_path = Path.join(tmp_dir, "sev")
  File.write!(wrapper_path, "old-wrapper")

  on_exit(fn -> File.rm_rf!(tmp_dir) end)

  original = System.get_env("__BURRITO_BIN_PATH")

  try do
    System.put_env("__BURRITO_BIN_PATH", wrapper_path)

    http_get = fn url ->
      if String.contains?(url, "api.github.com") do
        body =
          :json.encode(%{
            "tag_name" => "v99.0.0",
            "assets" => [
              %{
                "name" => "sev_macos_arm64",
                "browser_download_url" => "https://example.com/sev"
              }
            ]
          })

        {:ok, IO.iodata_to_binary(body)}
      else
        {:ok, "new-binary-content"}
      end
    end

    capture_io(fn ->
      assert Updater.run(
               http_get: http_get,
               arch: "aarch64-apple-darwin24.3.0"
             ) == :ok
    end)

    assert File.read!(wrapper_path) == "new-binary-content"
  after
    if original,
      do: System.put_env("__BURRITO_BIN_PATH", original),
      else: System.delete_env("__BURRITO_BIN_PATH")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/updater_test.exs --trace`
Expected: Fails — updater doesn't use `__BURRITO_BIN_PATH` for its default path.

- [ ] **Step 3: Replace `find_binary_path/0` to delegate to Init**

In `lib/severance/updater.ex`, replace `find_binary_path/0` (lines 227-230):

```elixir
@spec find_binary_path() :: String.t()
defp find_binary_path do
  Severance.Init.detect_binary_path()
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/updater_test.exs --trace`
Expected: All tests pass.

- [ ] **Step 5: Format and lint**

Run: `mix format lib/severance/updater.ex test/severance/updater_test.exs && mix credo --strict`

- [ ] **Step 6: Commit**

```bash
git add lib/severance/updater.ex test/severance/updater_test.exs
git commit -m "Updater delegates to Init.detect_binary_path"
```

---

### Task 3: Rewrite plist after successful update

**Files:**
- Modify: `lib/severance/updater.ex:134-160`
- Test: `test/severance/updater_test.exs`

- [ ] **Step 1: Write failing test that verifies plist rewrite after update**

Add to `test/severance/updater_test.exs` inside `describe "run/1"`:

```elixir
test "rewrites plist after successful update" do
  tmp_dir =
    Path.join(System.tmp_dir!(), "sev_update_test_#{System.unique_integer([:positive])}")

  File.mkdir_p!(tmp_dir)
  binary_path = Path.join(tmp_dir, "sev")
  plist_path = Path.join(tmp_dir, "com.severance.daemon.plist")
  File.write!(binary_path, "old-binary")

  on_exit(fn -> File.rm_rf!(tmp_dir) end)

  http_get = fn url ->
    if String.contains?(url, "api.github.com") do
      body =
        :json.encode(%{
          "tag_name" => "v99.0.0",
          "assets" => [
            %{
              "name" => "sev_macos_arm64",
              "browser_download_url" => "https://example.com/sev"
            }
          ]
        })

      {:ok, IO.iodata_to_binary(body)}
    else
      {:ok, "new-binary-content"}
    end
  end

  capture_io(fn ->
    assert Updater.run(
             http_get: http_get,
             binary_path: binary_path,
             arch: "aarch64-apple-darwin24.3.0",
             plist_path: plist_path
           ) == :ok
  end)

  plist_content = File.read!(plist_path)
  assert plist_content =~ binary_path
  assert plist_content =~ "com.severance.daemon"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/severance/updater_test.exs --trace`
Expected: Fails — no plist file is written by the updater, and `:plist_path` opt is not recognized.

- [ ] **Step 3: Add plist rewrite to `run/0`**

In `lib/severance/updater.ex`, modify the `run/1` function. Add a `:plist_path` option and call a new `rewrite_plist/2` function after `write_binary`:

At the top of `run/1`, add the plist_path opt extraction after the existing opts:

```elixir
plist_path = Keyword.get(opts, :plist_path)
```

Replace the success path of the `with` block (line 148-149) — between `write_binary` and `maybe_restart_daemon`:

```elixir
     :ok <- write_binary(bin_path, data) do
      rewrite_plist(bin_path, plist_path)
      maybe_restart_daemon(latest, bin_path, opts)
```

Add the `rewrite_plist/2` private function:

```elixir
@spec rewrite_plist(String.t(), String.t() | nil) :: :ok
defp rewrite_plist(binary_path, plist_path) do
  path = plist_path || default_plist_path()
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, Severance.Init.plist_contents(binary_path))
  IO.puts("[plist] Updated #{path}")
  :ok
end

@spec default_plist_path() :: String.t()
defp default_plist_path do
  Path.expand("~/Library/LaunchAgents/com.severance.daemon.plist")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/severance/updater_test.exs --trace`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite for both changed modules**

Run: `mix test test/severance/updater_test.exs test/severance/init_test.exs --trace`
Expected: All tests pass.

- [ ] **Step 6: Format and lint**

Run: `mix format lib/severance/updater.ex test/severance/updater_test.exs && mix credo --strict`

- [ ] **Step 7: Commit**

```bash
git add lib/severance/updater.ex test/severance/updater_test.exs
git commit -m "Rewrite plist after successful update"
```
