#!/bin/sh
# Exercise build defaults with a local Git source; no credentials or network.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p "$scratch/source/data/example/model" "$scratch/context/data" "$scratch/context/release"
printf '{"files":{}}\n' > "$scratch/source/data/manifest.json"
printf 'unqualified source bytes\n' > "$scratch/source/data/example/model/metadata.json"
git init --quiet "$scratch/source"
git -C "$scratch/source" add data
git -C "$scratch/source" -c core.hooksPath=/dev/null -c user.name=BuildTest -c user.email=build-test@example.invalid commit --quiet -m 'test source'
BENCHMARK_REVISION=$(git -C "$scratch/source" rev-parse HEAD)
BENCHMARK_DATA_REPOSITORY=$scratch/source
export BENCHMARK_REVISION BENCHMARK_DATA_REPOSITORY
unset VALIDATE_RELEASE CATALOG_REVISION CATALOG_DATA_REPOSITORY

printf 'models: []\n' > "$scratch/context/data/models-catalog.yaml"
printf 'producer-only index\n' > "$scratch/context/data/models-index.yaml"
printf '# Runtime files\nmodels-catalog.yaml\n' > "$scratch/context/release/runtime-catalog-files.txt"
cd "$scratch/context"

# The source has no qualifier or approval report, and no loaders are supplied.
sh "$script_dir/prepare-image.sh" "$scratch/default"
cmp "$scratch/source/data/manifest.json" "$scratch/default/app/benchmarks/manifest.json"
cmp "$scratch/source/data/example/model/metadata.json" "$scratch/default/app/benchmarks/example/model/metadata.json"
cmp data/models-catalog.yaml "$scratch/default/app/data/models-catalog.yaml"
test ! -e "$scratch/default/app/data/models-index.yaml"
test ! -e "$scratch/default/app/benchmarks/.git"

# Enabling validation must require its inputs rather than fall back to copying.
if VALIDATE_RELEASE=true sh "$script_dir/prepare-image.sh" "$scratch/validated" > "$scratch/error" 2>&1; then
    echo 'validation unexpectedly accepted a missing catalog revision' >&2
    exit 1
fi
grep -F 'CATALOG_REVISION must be a full lowercase Git commit SHA' "$scratch/error"
test ! -e "$scratch/validated"

if VALIDATE_RELEASE=typo sh "$script_dir/prepare-image.sh" "$scratch/invalid" > "$scratch/error" 2>&1; then
    echo 'invalid validation flag unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'VALIDATE_RELEASE must be true or false' "$scratch/error"
test ! -e "$scratch/invalid"
echo 'Image preparation defaults and opt-in validation guards passed'
