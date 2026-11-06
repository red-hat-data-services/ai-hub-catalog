# Syncing with model-metadata-collection

This repository is a downstream of
[`red-hat-data-services/model-metadata-collection`](https://github.com/red-hat-data-services/model-metadata-collection)
(mmc), which contains
[`opendatahub-io/model-metadata-collection`](https://github.com/opendatahub-io/model-metadata-collection)
plus Red Hat fixes. It packages the catalogs for the RHOAI versions listed in
[`release/supported-model-catalog-versions.txt`](../../release/supported-model-catalog-versions.txt),
and ships off-cycle releases from the `release` branch.

Syncs are run by people, using `make sync-mmc`. The
[`sync-mmc` agent skill](../../.agents/skills/sync-mmc/SKILL.md) runs the same
procedure in Claude Code or Codex.

## Rules

- **Content changes go upstream first.** Models, MCP servers, agents, serving
  runtimes, and generator code belong in opendatahub-io/model-metadata-collection.
  They reach this repository through a sync.
- **Paths in [`upstream-paths`](upstream-paths) are taken whole from upstream.**
  Generated catalogs are never line-merged, and a downstream edit there is
  replaced by the next sync.
- **Paths in [`downstream-paths`](downstream-paths) are ours.** A sync keeps our
  version and lists upstream changes to them for review. These paths are the
  complete set of downstream-only files; keep the list current.
- **Everything else is merged normally.** Conflicts in shared files, such as
  `Makefile`, `go.mod`, and shared Go code, are resolved by hand.
- **Sync into `main` only.** `release` advances to validated `main` commits; fixes
  land on `main` first and are cherry-picked to `release`.
- **Merge sync PRs with a merge commit.** Squash or rebase loses the merge base,
  and the next sync will conflict on every change again.

## Procedure

```sh
git fetch origin
git switch -c sync/mmc-$(date +%Y-%m-%d) origin/main
make sync-mmc
```

`make sync-mmc` fetches mmc `main`, starts a `--no-ff` merge, applies the
ownership rules, refreshes the fixture benchmark report's catalog hashes, and
reports:

1. **Downstream edits to upstream-owned paths.** These are replaced. Make sure
   each one is upstream, or get it there.
2. **Upstream changes to downstream-owned paths.** Ours are kept. Decide whether
   each change is needed downstream. For example, a new catalog file in
   upstream's `Dockerfile` must also be added to
   `release/runtime-catalog-files.txt`.
3. **Release-branch fixes missing from upstream `main`** (see below).

If conflicts remain, it exits with status 2. Resolve them, `git add` each file,
and run `make sync-mmc-check`. Otherwise it runs the checks directly: `make ci`,
failing if that changes any tracked file (for example, `go mod tidy`).

Before committing, check the consumer impact:

- A catalog file added or removed upstream must match what supported RHOAI
  versions load: the shipped sources in each version's model-registry-operator
  `default-catalog-sources` ConfigMap. `scripts/check-runtime-catalogs.sh`
  mirrors that list.
- Models added, removed, or renamed can break benchmark qualification against the
  pinned `BENCHMARK_REVISION`. The Konflux PR build runs the real qualifier;
  `make docker-build` runs it locally.

Then commit, push to your fork, and open the PR from there:

```sh
git commit -s --no-edit
git push -u <your-fork-remote> HEAD
```

The PR description should list the upstream range, conflicts and how they were
resolved, downstream follow-ups, and user-visible catalog changes.

## Release-branch fixes

Fixes can land directly on mmc release branches (`rhoai-3.6`, `rhoai-3.7-ea.1`,
and so on) without reaching mmc `main`. `scripts/sync-mmc/sync-mmc.sh detect` scans the
`rhoai-X.Y*` branches at or above the oldest supported version. It lists every
commit whose patch is missing from mmc `main` and that touches content, meaning
paths outside [`plumbing-paths`](plumbing-paths). It also lists merges whose
conflict resolution changed content. A sync runs it too.

The detector prints the branches it scanned and fails when none match, which
means upstream renamed its release branches and the script needs updating.

For each reported commit, either forward-port the fix to `main`, preferably
upstream, or record it in [`acknowledged-commits`](acknowledged-commits) with a
reason.

## Benchmark pin

The image build fetches the private
[`models-perf-benchmark-data`](https://github.com/red-hat-data-services/models-perf-benchmark-data)
repository at the commit pinned in `ARG BENCHMARK_REVISION=` in the
`Dockerfile`. Moving that pin is separate from an mmc sync; run it on its own
branch, or on a sync branch when the two belong together:

```sh
make sync-benchmark                  # head of stable
make sync-benchmark REF=main         # head of another branch
make sync-benchmark REF=<full-sha>   # an exact commit
```

`REF` is a branch name or a full commit SHA. It defaults to `stable`. The
command resolves a branch to its head SHA, checks that a SHA exists in the
repository, rewrites only the pin line, and prints the old and new pin. It
fails on a short SHA, an unknown branch or commit, or a `Dockerfile` without
exactly one pin line. It does not commit, and it does not check that the new pin
is newer than the old one or approved for release: moving to a branch that is
behind the current pin works. Check where a branch stands before using it.

Run `make docker-build` afterwards. Qualification runs against the new pin and
the catalogs in the build, and a release build also requires the pinned commit
to be approved for release.

The command needs read access to the benchmark repository. Credentials come from
`GITHUB_TOKEN_FILE`, `GITHUB_TOKEN`, or an existing `gh` login, in that order,
as for `make docker-build`. Git only receives the token when it asks for one.

## Files

| File | Purpose |
| --- | --- |
| [`downstream-paths`](downstream-paths) | Paths owned by this repository |
| [`upstream-paths`](upstream-paths) | Paths taken whole from upstream |
| [`plumbing-paths`](plumbing-paths) | Build and CI paths the detector ignores |
| [`acknowledged-commits`](acknowledged-commits) | Release-branch commits no longer reported |
| [`sync-mmc.sh`](sync-mmc.sh) | `merge`, `check`, `detect`, and `benchmark` |
| [`test-sync-benchmark.sh`](test-sync-benchmark.sh) | Offline test of the benchmark pin update, run by `make ci` |

`UPSTREAM_REPOSITORY`, `UPSTREAM_BRANCH`, and `RELEASE_BRANCH_MIN` override the
defaults, and `BENCHMARK_DATA_REPOSITORY` overrides the benchmark repository.
The script needs Git 2.36 or later, Go, Make, and Python 3.
