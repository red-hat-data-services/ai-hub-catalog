#!/bin/sh
# Exercise the benchmark pin update against local Git repositories; no network
# and no credentials.
set -eu
script=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/sync-mmc.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

git_as_test() {
    git -c core.hooksPath=/dev/null -c user.name=SyncTest -c user.email=sync-test@example.invalid \
        -c commit.gpgsign=false "$@"
}

fail() {
    echo "test-sync-benchmark: $*" >&2
    exit 1
}

# A benchmark repository with three commits: stable is the oldest, main the newest.
source_repo=$scratch/benchmarks
git init --quiet -b main "$source_repo"
for n in 1 2 3; do
    echo "$n" > "$source_repo/data"
    git -C "$source_repo" add data
    git_as_test -C "$source_repo" commit --quiet -m "commit $n"
    eval "commit$n=$(git -C "$source_repo" rev-parse HEAD)"
    if [ "$n" = 1 ]; then git -C "$source_repo" branch stable; fi
done
BENCHMARK_DATA_REPOSITORY=$source_repo
export BENCHMARK_DATA_REPOSITORY
# The script may only run Git; credentials must not be needed for local paths.
GITHUB_TOKEN=
export GITHUB_TOKEN

# A downstream repository whose Dockerfile carries the pin.
repo=$scratch/repo
git init --quiet "$repo"
cd "$repo"
write_dockerfile() {
    printf 'FROM scratch\nARG BENCHMARK_REVISION=%s\nARG OTHER=keep\n' "$1" > Dockerfile
}
current_pin() {
    sed -n 's/^ARG BENCHMARK_REVISION=//p' Dockerfile
}
run_sync() {
    sh "$script" benchmark "$@" > "$scratch/out" 2> "$scratch/err"
}

expect_pin() {
    [ "$(current_pin)" = "$1" ] || fail "$2: pin is $(current_pin), want $1"
    grep -qx 'FROM scratch' Dockerfile && grep -qx 'ARG OTHER=keep' Dockerfile ||
        fail "$2: changed lines other than the pin"
}

old=0000000000000000000000000000000000000001

# No argument follows the default branch, stable.
write_dockerfile "$old"
run_sync || fail "default ref failed: $(cat "$scratch/err")"
expect_pin "$commit1" "default ref"
grep -q 'branch stable' "$scratch/out" || fail "default ref output does not name the branch"

# A named branch resolves to its head.
run_sync main || fail "branch main failed: $(cat "$scratch/err")"
expect_pin "$commit3" "branch main"

# A full SHA is accepted and can move the pin backwards.
run_sync "$commit2" || fail "explicit SHA failed: $(cat "$scratch/err")"
expect_pin "$commit2" "explicit SHA"
grep -q 'explicit SHA' "$scratch/out" || fail "explicit SHA output does not say so"

# The same pin again changes nothing.
run_sync "$commit2" || fail "repeat pin failed"
grep -q 'already' "$scratch/out" || fail "repeat pin did not say it is already pinned"
expect_pin "$commit2" "repeat pin"

# Bad refs fail and leave the Dockerfile alone.
reject() {
    if run_sync "$1"; then fail "$2: expected failure"; fi
    grep -q "$3" "$scratch/err" || fail "$2: unexpected error: $(cat "$scratch/err")"
    expect_pin "$commit2" "$2"
}
reject nosuchbranch "missing branch" "not found"
reject "$(printf %.7s "$commit3")" "short SHA" "not a full SHA"
reject 0123456789abcdef0123456789abcdef01234567 "unknown SHA" "not found"
reject "$(echo "$commit3" | tr 'a-f' 'A-F')" "uppercase SHA" "not found\|not a full SHA"

# An unreadable token file is reported by the script, and nothing changes.
if GITHUB_TOKEN_FILE=$scratch/missing-token run_sync main; then fail "unreadable token file: expected failure"; fi
grep -q 'sync-mmc: cannot read GITHUB_TOKEN_FILE' "$scratch/err" ||
    fail "unreadable token file: unexpected error: $(cat "$scratch/err")"
expect_pin "$commit2" "unreadable token file"

# A Dockerfile without exactly one pin line is refused.
printf 'FROM scratch\n' > Dockerfile
if run_sync main; then fail "missing pin line: expected failure"; fi
printf 'ARG BENCHMARK_REVISION=%s\nARG BENCHMARK_REVISION=%s\n' "$old" "$old" > Dockerfile
if run_sync main; then fail "duplicate pin line: expected failure"; fi
grep -q 'exactly one' "$scratch/err" || fail "duplicate pin line: unexpected error"

echo "test-sync-benchmark: ok"
