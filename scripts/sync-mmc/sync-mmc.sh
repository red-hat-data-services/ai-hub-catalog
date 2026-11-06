#!/bin/sh
# Synchronize this repository with red-hat-data-services/model-metadata-collection,
# which contains opendatahub-io/model-metadata-collection plus downstream fixes.
# Run by people; see scripts/sync-mmc/README.md.
#
#   scripts/sync-mmc/sync-mmc.sh [merge]  merge upstream main into the current sync branch
#   scripts/sync-mmc/sync-mmc.sh check    verify the merge before committing
#   scripts/sync-mmc/sync-mmc.sh detect   report release-branch fixes missing from upstream main
#   scripts/sync-mmc/sync-mmc.sh benchmark [REF]
#                                         pin models-perf-benchmark-data in the Dockerfile to
#                                         a branch head or a full SHA (default: stable)
#
# Nothing is committed by this script. Ownership rules live next to it.
set -eu

UPSTREAM_REPOSITORY=${UPSTREAM_REPOSITORY:-https://github.com/red-hat-data-services/model-metadata-collection.git}
UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-main}
BENCHMARK_DATA_REPOSITORY=${BENCHMARK_DATA_REPOSITORY:-https://github.com/red-hat-data-services/models-perf-benchmark-data.git}
BENCHMARK_DEFAULT_REF=stable
BENCHMARK_PIN_FILE=Dockerfile
# Upstream rhoai-X.Y* branches at or above this version are scanned for fixes.
# Defaults to the oldest RHOAI version this repository supports.
RELEASE_BRANCH_MIN=${RELEASE_BRANCH_MIN:-}
SUPPORTED_VERSIONS=release/supported-model-catalog-versions.txt
FIXTURE_REPORT=internal/releasecandidate/testdata/benchmark-qualification-report.json
REF_PREFIX=refs/sync/mmc
SYNC_DIR=scripts/sync-mmc

cd "$(git rev-parse --show-toplevel)"

die() {
    echo "sync-mmc: $*" >&2
    exit 1
}

section() {
    printf '\n== %s\n' "$*"
}

run() {
    echo "+ $*"
    "$@"
}

# Literal file or directory paths, one per line; '#' starts a comment.
read_paths() {
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# Make every tracked path under the paths listed in $2 match revision $1:
# checked out when it exists there, removed otherwise. Unlike git restore, this
# also resolves modify/delete conflicts.
take_side() {
    read_paths "$2" | while IFS= read -r spec; do
        git ls-files -- "$spec"
        git ls-tree -r --name-only "$1" -- "$spec"
    done | sort -u | while IFS= read -r path; do
        if git cat-file -e "$1:$path" 2>/dev/null; then
            git checkout -q "$1" -- "$path"
        else
            git rm -q -f -- "$path"
        fi
    done
}

# Files changed between two revisions under the paths listed in $3.
list_changes() {
    changes=$(read_paths "$3" | while IFS= read -r spec; do
        git diff --name-status "$1" "$2" -- "$spec"
    done)
    if [ -n "$changes" ]; then
        printf '%s\n' "$changes" | sed 's/^/  /'
    else
        echo "  (none)"
    fi
}

# Filter out paths listed in plumbing-paths. An entry ending in / matches
# everything below it; any other entry matches one file.
content_paths() {
    awk 'FILENAME == ARGV[1] {
            sub(/#.*/, ""); sub(/[ \t]+$/, "")
            if ($0 != "") plumbing[$0] = 1
            next
        }
        {
            for (entry in plumbing)
                if ($0 == entry || (entry ~ /\/$/ && index($0, entry) == 1)) next
            print
        }' "$SYNC_DIR/plumbing-paths" -
}

release_branch_min() {
    if [ -n "$RELEASE_BRANCH_MIN" ]; then
        echo "$RELEASE_BRANCH_MIN"
        return
    fi
    min=$(read_paths "$SUPPORTED_VERSIONS" | sed -n 's/^rhoai-\([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' |
        sort -t. -k1,1n -k2,2n | head -n 1)
    [ -n "$min" ] || die "no rhoai-X.Y version in $SUPPORTED_VERSIONS; set RELEASE_BRANCH_MIN"
    echo "$min"
}

release_branches() {
    min=$(release_branch_min)
    min_major=${min%%.*}
    min_minor=${min#*.}
    git ls-remote --heads "$UPSTREAM_REPOSITORY" 'rhoai-*' | sed 's|.*refs/heads/||' |
    while IFS= read -r branch; do
        version=$(printf '%s\n' "$branch" | sed -n 's/^rhoai-\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
        [ -n "$version" ] || continue
        major=${version% *}
        minor=${version#* }
        if [ "$major" -gt "$min_major" ] || { [ "$major" -eq "$min_major" ] && [ "$minor" -ge "$min_minor" ]; }; then
            printf '%s\n' "$branch"
        fi
    done
}

fetch_upstream() {
    git show --remerge-diff -s HEAD >/dev/null 2>&1 || die "git 2.36 or later is required"
    branches=$(release_branches)
    # Drop release refs from earlier runs so deleted upstream branches vanish.
    git for-each-ref --format='%(refname)' "$REF_PREFIX/" | while IFS= read -r ref; do
        git update-ref -d "$ref"
    done
    set -- "+refs/heads/$UPSTREAM_BRANCH:$REF_PREFIX/$UPSTREAM_BRANCH"
    for branch in $branches; do
        set -- "$@" "+refs/heads/$branch:$REF_PREFIX/$branch"
    done
    git fetch -q --no-tags "$UPSTREAM_REPOSITORY" "$@"
}

release_refs() {
    git for-each-ref --format='%(refname)' "$REF_PREFIX/rhoai-*"
}

# Print content commits on upstream release branches that upstream main lacks.
# Prints nothing when every such fix is upstream or acknowledged.
release_fixes() {
    upstream=$REF_PREFIX/$UPSTREAM_BRANCH
    seen=
    for ref in $(release_refs); do
        # Commits whose patch is not on main, plus merges, which git cherry
        # skips. A merge's remerge diff holds changes made while resolving it.
        for commit in $(git cherry "$upstream" "$ref" | sed -n 's/^+ //p') \
            $(git rev-list --merges "$upstream..$ref"); do
            case "$seen" in *"$commit"*) continue ;; esac
            seen="$seen $commit"
            if read_paths "$SYNC_DIR/acknowledged-commits" | grep -q "^$commit"; then
                continue
            fi
            content=$(git show --remerge-diff --format= --name-only "$commit" | content_paths)
            [ -n "$content" ] || continue
            echo "  ${ref#"$REF_PREFIX"/}: $(git log -1 --format='%H %an: %s' "$commit")"
            printf '%s\n' "$content" | sed 's/^/      /'
        done
    done
}

report_release_fixes() {
    section "Release-branch fixes missing from upstream $UPSTREAM_BRANCH"
    scanned=$(release_refs | sed "s|^$REF_PREFIX/||" | tr '\n' ' ')
    if [ -z "$scanned" ]; then
        echo "  No upstream branch matched rhoai-X.Y at or above $(release_branch_min)."
        echo "  Nothing was scanned; check whether upstream renamed its release branches."
        return 1
    fi
    echo "  Scanned: $scanned"
    fixes=$(release_fixes)
    if [ -z "$fixes" ]; then
        echo "  (none)"
        return 0
    fi
    printf '%s\n' "$fixes"
    echo "Forward-port each fix to main, or record it in $SYNC_DIR/acknowledged-commits."
    return 1
}

# The fixture report pins the hashes of the live catalogs the benchmark
# qualifier reads, so it must follow every catalog change. Remove this step
# once the fixture has its own catalogs.
refresh_fixture_hashes() {
    [ -f "$FIXTURE_REPORT" ] || return 0
    python3 -I - "$FIXTURE_REPORT" data <<'EOF'
import hashlib, json, pathlib, sys
report, data = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
document = json.loads(report.read_text())
for entry in document["catalog"]["files"]:
    entry["sha256"] = hashlib.sha256((data / entry["name"]).read_bytes()).hexdigest()
report.write_text(json.dumps(document, indent=2) + "\n")
EOF
    git add "$FIXTURE_REPORT"
}

check() {
    if git diff --name-only --diff-filter=U | grep -q .; then
        die "unresolved conflicts remain; resolve them and git add the files"
    fi
    if git diff --cached --check HEAD | grep 'conflict marker'; then
        die "leftover conflict markers"
    fi
    git diff --quiet || die "unstaged changes; git add the resolved files first"
    section "Checks"
    # make ci is the repository's definition of passing. Its deps step runs
    # go mod tidy, so any change it makes means the merge is not tidy.
    run make ci
    if ! git diff --quiet; then
        git diff --stat
        die "make ci changed tracked files; review the changes and git add them"
    fi
    section "Checks passed"
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        echo "Review with 'git diff --cached HEAD', then commit with 'git commit -s --no-edit'."
    fi
}

merge() {
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        die "a merge is already in progress; finish it or run 'git merge --abort'"
    fi
    git diff --quiet && git diff --cached --quiet || die "commit or stash tracked changes first"
    current=$(git symbolic-ref --short -q HEAD) || die "check out a branch first"
    case "$current" in
        main | release) die "run on a sync branch: git switch -c sync/mmc-$(date +%Y-%m-%d) origin/main" ;;
    esac

    section "Fetching $UPSTREAM_REPOSITORY"
    fetch_upstream
    upstream=$REF_PREFIX/$UPSTREAM_BRANCH
    revision=$(git rev-parse "$upstream")
    if git merge-base --is-ancestor "$upstream" HEAD; then
        echo "Already contains $UPSTREAM_BRANCH at $revision"
        report_release_fixes || true
        return 0
    fi
    base=$(git merge-base HEAD "$upstream")

    section "Downstream edits to upstream-owned paths (replaced by upstream)"
    list_changes "$base" HEAD "$SYNC_DIR/upstream-paths"
    section "Upstream changes to downstream-owned paths (ours kept; review them)"
    list_changes "$base" "$upstream" "$SYNC_DIR/downstream-paths"

    section "Merging $UPSTREAM_BRANCH at $revision"
    git merge --no-ff --no-commit -m "chore(sync): merge model-metadata-collection $UPSTREAM_BRANCH

Upstream: $UPSTREAM_REPOSITORY
Revision: $revision" "$upstream" >/dev/null 2>&1 || true
    git rev-parse -q --verify MERGE_HEAD >/dev/null || die "git merge did not start; run it manually to see why"
    take_side HEAD "$SYNC_DIR/downstream-paths"
    take_side "$upstream" "$SYNC_DIR/upstream-paths"
    refresh_fixture_hashes
    fixes_found=0
    report_release_fixes || fixes_found=1

    conflicts=$(git diff --name-only --diff-filter=U)
    if [ -n "$conflicts" ]; then
        section "Unresolved conflicts"
        printf '  %s\n' $conflicts
        echo "Resolve them (see $SYNC_DIR/README.md), git add each file, then run 'make sync-mmc-check'."
        exit 2
    fi
    check
    if [ "$fixes_found" = 1 ]; then
        echo "Release-branch findings are listed above; handle them before committing."
    fi
}

# Full lowercase Git commit SHA, as the Dockerfile and prepare-image.sh require.
is_revision() {
    case "$1" in
        '' | *[!0-9a-f]*) return 1 ;;
    esac
    case "${#1}" in
        40 | 64) return 0 ;;
        *) return 1 ;;
    esac
}

# The benchmark repository is private. Git reads the token only when it asks
# for one; it never goes into a URL, a command argument, or Git configuration.
# Credentials come from the same places as make docker-build.
benchmark_git_auth() {
    token=
    if [ -n "${GITHUB_TOKEN_FILE:-}" ]; then
        token=$(cat "$GITHUB_TOKEN_FILE") || die "cannot read GITHUB_TOKEN_FILE $GITHUB_TOKEN_FILE"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        token=$GITHUB_TOKEN
    elif command -v gh >/dev/null 2>&1; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    [ -n "$token" ] || return 0
    cat > "$scratch/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *) printf '%s\n' "$SYNC_MMC_GITHUB_TOKEN" ;;
esac
ASKPASS
    chmod 700 "$scratch/askpass"
    SYNC_MMC_GITHUB_TOKEN=$token
    export SYNC_MMC_GITHUB_TOKEN GIT_ASKPASS="$scratch/askpass" GIT_TERMINAL_PROMPT=0
}

# Point the Dockerfile's BENCHMARK_REVISION at a branch head or a full SHA of
# models-perf-benchmark-data. Only Git is run against that repository; none of
# its code is executed.
benchmark() {
    ref=${1:-$BENCHMARK_DEFAULT_REF}
    [ "$(grep -c '^ARG BENCHMARK_REVISION=' "$BENCHMARK_PIN_FILE")" = 1 ] ||
        die "expected exactly one 'ARG BENCHMARK_REVISION=' line in $BENCHMARK_PIN_FILE"
    old=$(sed -n 's/^ARG BENCHMARK_REVISION=//p' "$BENCHMARK_PIN_FILE")
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT HUP INT TERM
    benchmark_git_auth

    if is_revision "$ref"; then
        revision=$ref
        source="explicit SHA"
        object_format=sha1
        if [ "${#revision}" = 64 ]; then object_format=sha256; fi
        # A typo or a commit from another repository fails here, not in docker build.
        git init --quiet --object-format="$object_format" "$scratch/probe"
        git -C "$scratch/probe" fetch --quiet --depth=1 --no-tags -- "$BENCHMARK_DATA_REPOSITORY" "$revision" 2>/dev/null ||
            die "commit $revision not found in $BENCHMARK_DATA_REPOSITORY"
        [ "$(git -C "$scratch/probe" rev-parse FETCH_HEAD)" = "$revision" ] ||
            die "fetched commit does not match $revision"
    else
        case "$ref" in
            *[!0-9a-f]*) ;;
            *) die "'$ref' is not a full SHA; pass the full commit SHA or a branch name" ;;
        esac
        heads=$(git ls-remote --heads "$BENCHMARK_DATA_REPOSITORY" "refs/heads/$ref") ||
            die "could not list branches of $BENCHMARK_DATA_REPOSITORY"
        revision=$(printf '%s\n' "$heads" | awk -v ref="refs/heads/$ref" '$2 == ref { print $1 }')
        [ -n "$revision" ] || die "branch '$ref' not found in $BENCHMARK_DATA_REPOSITORY"
        source="branch $ref"
    fi

    if [ "$revision" = "$old" ]; then
        echo "Benchmark pin is already $revision ($source)"
        return 0
    fi
    sed "s/^ARG BENCHMARK_REVISION=.*/ARG BENCHMARK_REVISION=$revision/" "$BENCHMARK_PIN_FILE" > "$scratch/pin-file"
    cat "$scratch/pin-file" > "$BENCHMARK_PIN_FILE"
    echo "Benchmark pin: $old -> $revision ($source)"
    echo "Review with 'git diff $BENCHMARK_PIN_FILE'. Run 'make docker-build' to qualify against the new pin."
}

case "${1:-merge}" in
    merge) merge ;;
    check) check ;;
    detect)
        fetch_upstream
        report_release_fixes
        ;;
    benchmark) benchmark "${2:-}" ;;
    *) die "usage: $0 [merge|check|detect|benchmark [REF]]" ;;
esac
