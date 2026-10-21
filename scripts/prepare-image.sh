#!/bin/sh
# Run inside the Dockerfile's preparation stage, with credentials mounted as
# secrets. Ordinary builds package the producer's test-qualified handoff. CI can
# opt into release qualification and consumer validation with VALIDATE_RELEASE=true.
set -eu

require_revision() {
    case "$2" in
        ''|*[!0-9a-f]*) echo "$1 must be a full lowercase Git commit SHA" >&2; exit 2 ;;
    esac
    case "${#2}" in
        40|64) ;;
        *) echo "$1 must be a full lowercase Git commit SHA" >&2; exit 2 ;;
    esac
}

require_revision BENCHMARK_REVISION "${BENCHMARK_REVISION:-}"
validate_release=${VALIDATE_RELEASE-false}
case "$validate_release" in
    false) qualification_mode=test ;;
    true) qualification_mode=release ;;
    *) echo "VALIDATE_RELEASE must be true or false" >&2; exit 2 ;;
esac
require_revision CATALOG_REVISION "${CATALOG_REVISION:-}"
source_root=$(pwd)
output=${1:-/prepared}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

# The token is read only when Git asks for it; it is never put into a URL,
# Git configuration, command argument, or image layer.
cat > "$scratch/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *) cat /run/secrets/models-perf-benchmark-data-clone/token 2>/dev/null \
       || cat /run/secrets/github_token ;;
esac
ASKPASS
chmod 700 "$scratch/askpass"
export GIT_ASKPASS="$scratch/askpass" GIT_TERMINAL_PROMPT=0

fetch_commit() {
    repository=$1
    revision=$2
    destination=$3
    object_format=sha1
    if [ "${#revision}" = 64 ]; then object_format=sha256; fi
    git init --quiet --object-format="$object_format" "$destination"
    git -C "$destination" fetch --quiet --depth=1 --no-tags -- "$repository" "$revision"
    git -C "$destination" checkout --quiet --detach FETCH_HEAD
    test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
}

fetch_commit "$BENCHMARK_DATA_REPOSITORY" "$BENCHMARK_REVISION" "$scratch/benchmarks"
printf 'Fetched benchmark commit %s\n' "$BENCHMARK_REVISION"

fetch_commit "$CATALOG_DATA_REPOSITORY" "$CATALOG_REVISION" "$scratch/catalog"
printf 'Fetched catalog commit %s for benchmark qualification\n' "$CATALOG_REVISION"

# Bind the catalog files in this build context to the committed candidate that
# the producer qualifies. A stale or unrelated CATALOG_REVISION must fail.
while IFS= read -r file; do
    case "$file" in ''|\#*) continue ;; esac
    if ! cmp "$source_root/data/$file" "$scratch/catalog/data/$file"; then
        echo "Catalog file $file differs from CATALOG_REVISION" >&2
        exit 1
    fi
done < release/runtime-catalog-files.txt

python3.12 "$scratch/benchmarks/api-client/qualify.py" \
    --benchmark-repo "$scratch/benchmarks" \
    --catalog-repo "$scratch/catalog" \
    --benchmark-revision "$BENCHMARK_REVISION" \
    --catalog-revision "$CATALOG_REVISION" \
    --handoff-dir "$scratch/handoff" \
    --mode "$qualification_mode"

if [ "$validate_release" = false ]; then
    mkdir -p "$output/app/data" "$output/app/benchmarks"
    cp -a "$scratch/handoff/benchmarks/." "$output/app/benchmarks/"
    while IFS= read -r file; do
        case "$file" in ''|\#*) continue ;; esac
        cp "$source_root/data/$file" "$output/app/data/$file"
    done < release/runtime-catalog-files.txt
    echo "Packaged test-qualified benchmarks; release validation disabled, not eligible for release promotion"
    exit 0
fi

mkdir "$scratch/loader-checks"
while IFS= read -r version; do
    case "$version" in ''|\#*) continue ;; esac
    if [ ! -s "/run/secrets/$version" ]; then
        echo "Missing release loader check: supply --secret id=$version,src=/path/to/$version" >&2
        exit 2
    fi
    cp "/run/secrets/$version" "$scratch/loader-checks/$version"
    chmod 700 "$scratch/loader-checks/$version"
done < release/supported-model-catalog-versions.txt

release-candidate \
    --catalog-dir "$source_root/data" \
    --producer-input-dir "$source_root/input" \
    --benchmark-dir "$scratch/handoff/benchmarks" \
    --benchmark-qualification-report "$scratch/handoff/qualification-report.json" \
    --benchmark-qualification-mode release \
    --runtime-files "$source_root/release/runtime-catalog-files.txt" \
    --supported-version-list "$source_root/release/supported-model-catalog-versions.txt" \
    --loader-check-dir "$scratch/loader-checks" \
    --output-dir "$output"
