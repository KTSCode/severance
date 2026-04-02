# Updater Plist Fix Design

Fix `sev update` so it (a) replaces the correct binary and (b) keeps the
LaunchAgent plist pointing to the stable wrapper path.

## Problem

Three related bugs in the update/init flow:

1. **`Init.detect_binary_path/0`** calls `System.find_executable("sev")` which,
   inside a Burrito-wrapped process, resolves to the extracted binary under
   `~/Library/Application Support/.burrito/` instead of the wrapper at
   `~/bin/sev`. The plist ends up pointing to a versioned extraction path
   that breaks after the next update.

2. **`Updater.find_binary_path/0`** has the same problem. `write_binary/2`
   overwrites the extracted binary instead of the wrapper. The wrapper is
   never updated, so the next launch re-extracts the old version.

3. **`Updater.run/0`** does not rewrite the plist after a successful update.
   Even if the binary path were correct, the plist would still reference the
   previous version's extraction directory.

## Fix

### 1. `Init.detect_binary_path/0` -- prefer Burrito wrapper path

Use `Burrito.Util.Args.get_bin_path/0` when running inside Burrito. It reads
`__BURRITO_BIN_PATH`, which the Zig wrapper sets to the resolved path of the
original wrapper binary before `execve`. Falls back to
`System.find_executable("sev")` when not in Burrito (dev/test).

```elixir
def detect_binary_path do
  case burrito_bin_path() do
    path when is_binary(path) -> path
    :not_in_burrito -> System.find_executable("sev") || "#{File.cwd!()}/burrito_out/sev"
  end
end

defp burrito_bin_path do
  if Code.ensure_loaded?(Burrito.Util.Args) do
    Burrito.Util.Args.get_bin_path()
  else
    :not_in_burrito
  end
end
```

### 2. `Updater.find_binary_path/0` -- delegate to Init

Replace the standalone `System.find_executable("sev")` call with
`Severance.Init.detect_binary_path/0`.

### 3. `Updater.run/0` -- rewrite plist after update

After `write_binary/2` succeeds and before the daemon restart prompt, call
`Severance.Init.create_plist/0`. The plist now points to the wrapper path
(via the fixed `detect_binary_path`).

Sequence after a successful download:

1. `write_binary/2` -- overwrite the wrapper
2. `Init.create_plist/0` -- rewrite plist pointing to wrapper
3. `maybe_restart_daemon/3` -- stop/restart if running

### Cleanup of old extractions

Not needed. Burrito's `maintenance.zig:do_clean_old_versions` deletes older
extraction directories automatically on the next launch of the updated wrapper.

## Files Changed

- `lib/severance/init.ex` -- `detect_binary_path/0`, add `burrito_bin_path/0`
- `lib/severance/updater.ex` -- `find_binary_path/0`, add plist rewrite in `run/0`

## Testing

- `Init.detect_binary_path/0` -- test with injected/mocked Burrito path
- `Updater.run/0` -- existing test infrastructure uses `:binary_path` opt
  injection; verify plist is rewritten after update by checking the plist file
  contents point to the wrapper path
