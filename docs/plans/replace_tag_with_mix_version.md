# Replace DIY `mix tag` with `mix_version`

## Context

The custom `Mix.Tasks.Tag` handles version bumping, changelog finalization, and git operations
in ~320 lines. `mix_version` handles version bump + commit + tag out of the box. By extracting
changelog management into its own task and delegating version work to `mix_version`, we reduce
custom code and align with community tooling.

## Trade-off

This splits the single release commit into two: one for the changelog, one for the version bump.
The git history goes from:

    Release v0.6.0  (modifies mix.exs + CHANGELOG.md)

to:

    v0.6.0                    (modifies mix.exs, tagged v0.6.0)
    Finalize changelog 0.6.0  (modifies CHANGELOG.md)

## Steps

### 1. Add `mix_version` dependency

In `mix.exs` deps:

```elixir
{:mix_version, "~> 2.4", only: [:dev, :test], runtime: false}
```

Add `:versioning` to `project/0`:

```elixir
versioning: [
  tag_prefix: "v",
  commit_msg: "v%s",
  annotate: true,
  annotation: "Release %s"
]
```

### 2. Create `lib/mix/tasks/changelog/finalize.ex`

Extract from the existing `tag.ex`:
- `unreleased_entries/1` -- validates [Unreleased] section has entries
- `finalize_changelog/3` -- moves entries under a versioned heading
- `confirm_release/3` -- shows entries and prompts y/N

New task accepts `--major`, `--minor`, or `--patch`, computes the new version
(to write the changelog heading), finalizes CHANGELOG.md, and commits it:

```bash
git add CHANGELOG.md
git commit -m "Finalize changelog for <new_version>"
```

### 3. Replace function alias in `mix.exs`

Update `aliases/0`:

```elixir
defp aliases do
  [
    tag: &tag_release/1,
    tidewave: "run --no-halt ..."
  ]
end

defp tag_release(args) do
  # Safety checks before anything runs
  Mix.Task.run("changelog.finalize", args)
  Mix.Task.run("version", args)
  {_, 0} = System.cmd("git", ["push", "--atomic", "origin", "HEAD"] ++ tag_ref(args))
end
```

### 4. Delete `lib/mix/tasks/tag.ex`

All functionality is now covered by:
- `mix_version` -- version bump, commit, tag
- `Mix.Tasks.Changelog.Finalize` -- changelog management
- Function alias -- orchestration + push + safety checks

### 5. Move safety checks

The existing safety checks (main branch, clean worktree, up-to-date with origin) should
move into `tag_release/1` so they run before either task starts.

### 6. Update tests

- Keep tests for `unreleased_entries/1` and `finalize_changelog/3` (move to new module)
- Remove tests for `bump_version/2`, `update_version_in_mix/2`, `parse_component/1`
  (now handled by mix_version)

### 7. Verify

- `mix tag --patch` -> finalizes changelog, bumps version, commits, tags, pushes
- Confirm CI release workflow triggers on the new tag
- Confirm changelog has correct version heading and date

## Files to modify

- `mix.exs` -- add dep, versioning config, update aliases
- `lib/mix/tasks/changelog/finalize.ex` -- new task (extracted from tag.ex)
- `lib/mix/tasks/tag.ex` -- delete
- `test/mix/tasks/tag_test.exs` -- update/move tests
