#!/bin/sh
# Run inside the Dockerfile's preparation stage, with credentials mounted as
# secrets. The official producer qualifier and the consumer validator both
# have to succeed before the runtime image can copy /prepared/app.
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
require_revision CATALOG_REVISION "${CATALOG_REVISION:-}"
qualification_mode=${BENCHMARK_QUALIFICATION_MODE-release}
case "$qualification_mode" in
    release) ;;
    test) echo "Building with testing approval; this image is not eligible for release promotion" ;;
    *) echo "BENCHMARK_QUALIFICATION_MODE must be release or test" >&2; exit 2 ;;
esac
skip_loader_checks=${SKIP_MODEL_CATALOG_LOADER_CHECKS-false}
case "$skip_loader_checks" in
    false) ;;
    true)
        if [ "$qualification_mode" != test ]; then
            echo "SKIP_MODEL_CATALOG_LOADER_CHECKS=true requires BENCHMARK_QUALIFICATION_MODE=test" >&2
            exit 2
        fi
        echo "Skipping Model Catalog loader checks for this test image"
        ;;
    *) echo "SKIP_MODEL_CATALOG_LOADER_CHECKS must be true or false" >&2; exit 2 ;;
esac
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
    *) cat /run/secrets/github_token ;;
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
fetch_commit "$CATALOG_DATA_REPOSITORY" "$CATALOG_REVISION" "$scratch/catalog"
printf 'Fetched benchmark commit %s and catalog commit %s\n' "$BENCHMARK_REVISION" "$CATALOG_REVISION"

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

mkdir "$scratch/loader-checks"
if [ "$skip_loader_checks" = false ]; then
    while IFS= read -r version; do
        case "$version" in ''|\#*) continue ;; esac
        if [ ! -s "/run/secrets/$version" ]; then
            echo "Missing release loader check: supply --secret id=$version,src=/path/to/$version" >&2
            exit 2
        fi
        cp "/run/secrets/$version" "$scratch/loader-checks/$version"
        chmod 700 "$scratch/loader-checks/$version"
    done < release/supported-model-catalog-versions.txt
fi

release-candidate \
    --catalog-dir "$source_root/data" \
    --producer-input-dir "$source_root/input" \
    --benchmark-dir "$scratch/handoff/benchmarks" \
    --benchmark-qualification-report "$scratch/handoff/qualification-report.json" \
    --benchmark-qualification-mode "$qualification_mode" \
    --skip-loader-checks="$skip_loader_checks" \
    --runtime-files "$source_root/release/runtime-catalog-files.txt" \
    --supported-version-list "$source_root/release/supported-model-catalog-versions.txt" \
    --loader-check-dir "$scratch/loader-checks" \
    --output-dir "$output"
