# `mix tag` Design

Mix task that bumps the application version, finalizes the changelog, and
pushes a git tag to trigger the CI release workflow.

## Usage

```bash
mix tag maj   # 0.1.0 → 1.0.0
mix tag min   # 0.1.0 → 0.2.0
mix tag pat   # 0.1.0 → 0.1.1
```

## Flow

1. **Guard:** Verify current git branch is `main`. Abort if not.
2. **Parse arg:** Accept `maj`, `min`, or `pat`. Reject anything else.
3. **Bump version:** Read current version from `mix.exs`, compute new version.
4. **Finalize changelog:** Move `[Unreleased]` entries under a new
   `[X.Y.Z] -- YYYY-MM-DD` heading. Add a fresh empty `[Unreleased]` section.
5. **Guard:** If `[Unreleased]` has no entries, abort. No empty releases.
6. **Show diff:** Print proposed changelog changes to stderr, prompt for
   approval (`y/N`).
7. **Write files:** Update version in `mix.exs`, write `CHANGELOG.md`.
8. **Commit:** `git add mix.exs CHANGELOG.md && git commit -m "Release vX.Y.Z"`
9. **Tag:** `git tag vX.Y.Z`
10. **Push:** `git push && git push --tags`

## Module Structure

`Mix.Tasks.Tag` in `lib/mix/tasks/tag.ex`.

Pure functions are public and tested:

- `bump_version(current, :maj | :min | :pat)` -- returns new version string
- `update_version_in_mix(mix_content, new_version)` -- replaces version in
  mix.exs content
- `finalize_changelog(changelog, new_version, date)` -- moves unreleased
  entries under a versioned heading, adds fresh unreleased section
- `unreleased_entries(changelog)` -- extracts entries under `[Unreleased]`,
  returns `{:ok, entries}` or `{:error, :empty_unreleased}`

Side-effect helpers are private, following the same pattern as `mix todo`:

- `current_branch()` -- shells out to `git rev-parse --abbrev-ref HEAD`
- `cmd/2` -- reuses the `System.cmd` wrapper pattern from `mix todo`

## Decisions

- **No `gh release create`:** CI workflow already handles release creation
  on tag push via `softprops/action-gh-release`.
- **Commit message:** `"Release vX.Y.Z"` -- no body, matches the
  convention for small mechanical changes.
- **Empty unreleased guard:** Prevents accidentally tagging a release with
  no changelog entries.
- **Main branch guard:** Prevents tagging from feature branches.
- **Changelog format:** Follows Keep a Changelog, consistent with existing
  `CHANGELOG.md` and `mix todo` conventions.

## What This Does Not Do

- No branch creation -- runs on `main` only.
- No PR -- direct commit + tag to `main`.
- No binary building -- CI handles that.
- No GitHub release creation -- CI handles that.
