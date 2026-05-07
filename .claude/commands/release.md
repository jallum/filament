Release a new version of filament.

Argument: `$ARGUMENTS` — the bump type (`major`, `minor`, or `patch`) or an explicit version (e.g., `0.2.0`). Default to `patch` if omitted.

## Preflight

1. Verify the working tree is clean (`git status`). Abort if there are uncommitted changes.
2. Read the current version from the `version:` field in `mix.exs`.
3. Calculate the new version based on the argument.
4. Verify the tag `vX.Y.Z` does not already exist (`git tag --list "vX.Y.Z"`). Abort if it does.

## Changelog

1. Run `git log <latest-tag>..HEAD --oneline` (or `git log --oneline` if no tags exist) to see all changes since the last release.
2. Read `CHANGELOG.md` — the `## [Unreleased]` section already has the accumulated entries; use it as the source of truth, supplemented by the git log for anything missing.
3. For each significant change, read the relevant code and diff to understand what actually changed.
4. Draft the new entry by promoting the `[Unreleased]` content to a versioned section and resetting `[Unreleased]` to empty skeleton headers.

New entry format:
```
## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...
```

Drop any section headers that have no entries. Reset `## [Unreleased]` to all six empty headers (Added, Changed, Deprecated, Removed, Fixed, Security).

Guidelines for changelog entries:

- Write for library consumers, not implementors.
- Describe what changed from the user's perspective.
- Group related commits into a single bullet.
- Skip trivial changes (typo fixes, CI tweaks, internal refactors) unless they're the only changes.
- For new, changed, or removed public API, include the rationale and where helpful a before/after code snippet — a bare bullet isn't enough for these.
- Match the tone and level of detail in existing entries.

5. **Present the draft changelog to the user for review.** Do not proceed until they approve or ask for edits.

## Version bump

1. Update the `version:` field in `mix.exs` to the new version string.
2. Update any `{:filament, "~> X.Y"}` version references in `README.md` to `"~> X.Y"` using the new major.minor (patch is omitted in `~>` constraints).

## Verify

1. Run `mix compile --warnings-as-errors` to verify compilation.
2. Run `mix test` to verify all tests pass. If tests fail, stop and fix before continuing.

## Ship

1. Commit all changes: `Bump version to X.Y.Z`
2. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`
3. Push: `git push && git push --tags`

## Publish

1. Run `mix hex.publish` and confirm when prompted. If the user is not authenticated, stop and tell them to run `mix hex.user auth` first, then re-run `/release`.
2. Report the hex.pm package URL: `https://hex.pm/packages/filament/X.Y.Z`
