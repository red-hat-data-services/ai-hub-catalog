#!/bin/sh
# Exercise qualification and staging with local Git sources and a synthetic
# producer qualifier; no private payload, credentials, or network.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

mkdir -p "$scratch/source/data/example/model" "$scratch/source/data/example/excluded" \
    "$scratch/source/api-client" "$scratch/context/data" "$scratch/context/release" "$scratch/bin"
printf '{"files":{"example/model/metadata.json":{},"example/excluded/metadata.json":{}}}\n' > "$scratch/source/data/manifest.json"
printf 'included model\n' > "$scratch/source/data/example/model/metadata.json"
printf 'excluded model\n' > "$scratch/source/data/example/excluded/metadata.json"

# The fixture producer returns a filtered handoff with its own manifest. This
# tests that preparation ships that handoff, never the unfiltered source tree.
cat > "$scratch/source/api-client/qualify.py" <<'QUALIFIER'
import argparse
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
for name in ("benchmark-repo", "catalog-repo", "benchmark-revision", "catalog-revision", "handoff-dir"):
    parser.add_argument("--" + name, required=True)
parser.add_argument("--mode", required=True, choices=("test", "release"))
args = parser.parse_args()
source = Path(args.benchmark_repo)
if args.mode == "release":
    raise SystemExit("release qualification rejects approved-for-testing policy")
if (source / "qualification-error").exists():
    raise SystemExit("benchmark qualification failed: new unmatched model")
handoff = Path(args.handoff_dir)
payload = handoff / "benchmarks"
model = "example/model/metadata.json"
(payload / model).parent.mkdir(parents=True)
shutil.copyfile(source / "data" / model, payload / model)
(payload / "manifest.json").write_text(json.dumps({"files": {model: {}}}) + "\n")
(handoff / "qualification-report.json").write_text(
    json.dumps({"qualification_mode": args.mode, "promotion_eligible": False}) + "\n"
)
QUALIFIER

# The synthetic qualifier uses only the standard library, so tests can run
# with the host's Python 3 while the image continues to use Python 3.12.
cat > "$scratch/bin/python3.12" <<'PYTHON'
#!/bin/sh
exec python3 "$@"
PYTHON
cat > "$scratch/bin/release-candidate" <<'VALIDATOR'
#!/bin/sh
echo 'default build unexpectedly invoked consumer release validation' >&2
exit 1
VALIDATOR
chmod +x "$scratch/bin/python3.12" "$scratch/bin/release-candidate"
PATH="$scratch/bin:$PATH"
export PATH

git init --quiet "$scratch/source"
git -C "$scratch/source" add data api-client
git -C "$scratch/source" -c core.hooksPath=/dev/null -c user.name=BuildTest -c user.email=build-test@example.invalid commit --quiet -m 'test source'
BENCHMARK_REVISION=$(git -C "$scratch/source" rev-parse HEAD)
BENCHMARK_DATA_REPOSITORY=$scratch/source
export BENCHMARK_REVISION BENCHMARK_DATA_REPOSITORY
unset VALIDATE_RELEASE

printf 'models: []\n' > "$scratch/context/data/models-catalog.yaml"
printf 'producer-only index\n' > "$scratch/context/data/models-index.yaml"
printf '# Runtime files\nmodels-catalog.yaml\n' > "$scratch/context/release/runtime-catalog-files.txt"
git init --quiet "$scratch/context"
git -C "$scratch/context" add data release
git -C "$scratch/context" -c core.hooksPath=/dev/null -c user.name=BuildTest -c user.email=build-test@example.invalid commit --quiet -m 'test catalog'
CATALOG_REVISION=$(git -C "$scratch/context" rev-parse HEAD)
CATALOG_DATA_REPOSITORY=$scratch/context
export CATALOG_REVISION CATALOG_DATA_REPOSITORY
cd "$scratch/context"

# No loaders are supplied. Qualification must still filter the default payload.
sh "$script_dir/prepare-image.sh" "$scratch/default"
cmp "$scratch/source/data/example/model/metadata.json" "$scratch/default/app/benchmarks/example/model/metadata.json"
test ! -e "$scratch/default/app/benchmarks/example/excluded"
python3 - "$scratch/default/app/benchmarks/manifest.json" <<'MANIFEST'
import json
import sys
with open(sys.argv[1]) as manifest:
    assert set(json.load(manifest)["files"]) == {"example/model/metadata.json"}
MANIFEST
cmp data/models-catalog.yaml "$scratch/default/app/data/models-catalog.yaml"
test ! -e "$scratch/default/app/data/models-index.yaml"
test ! -e "$scratch/default/app/benchmarks/.git"
test ! -e "$scratch/default/app/benchmarks/qualification-report.json"
test ! -e "$scratch/default/qualification-report.json"

# Both modes must qualify against immutable catalog bytes.
for validate in false true; do
    if CATALOG_REVISION= VALIDATE_RELEASE=$validate sh "$script_dir/prepare-image.sh" "$scratch/missing-catalog" > "$scratch/error" 2>&1; then
        echo 'qualification unexpectedly accepted a missing catalog revision' >&2
        exit 1
    fi
    grep -F 'CATALOG_REVISION must be a full lowercase Git commit SHA' "$scratch/error"
    test ! -e "$scratch/missing-catalog"
done

printf 'changed catalog\n' >> data/models-catalog.yaml
if sh "$script_dir/prepare-image.sh" "$scratch/changed-catalog" > "$scratch/error" 2>&1; then
    echo 'qualification unexpectedly accepted changed catalog bytes' >&2
    exit 1
fi
grep -F 'Catalog file models-catalog.yaml differs from CATALOG_REVISION' "$scratch/error"
test ! -e "$scratch/changed-catalog"
git show HEAD:data/models-catalog.yaml > data/models-catalog.yaml

# Release validation must select release qualification, without falling back
# to the testing policy or the raw source when its approval check fails.
if VALIDATE_RELEASE=true sh "$script_dir/prepare-image.sh" "$scratch/release" > "$scratch/error" 2>&1; then
    echo 'release validation unexpectedly accepted a testing-only policy' >&2
    exit 1
fi
grep -F 'release qualification rejects approved-for-testing policy' "$scratch/error"
test ! -e "$scratch/release"

touch "$scratch/source/qualification-error"
git -C "$scratch/source" add qualification-error
git -C "$scratch/source" -c core.hooksPath=/dev/null -c user.name=BuildTest -c user.email=build-test@example.invalid commit --quiet -m 'failing qualification'
BENCHMARK_REVISION=$(git -C "$scratch/source" rev-parse HEAD)
if sh "$script_dir/prepare-image.sh" "$scratch/failed" > "$scratch/error" 2>&1; then
    echo 'default build unexpectedly ignored qualification failure' >&2
    exit 1
fi
grep -F 'benchmark qualification failed: new unmatched model' "$scratch/error"
test ! -e "$scratch/failed"

if VALIDATE_RELEASE=typo sh "$script_dir/prepare-image.sh" "$scratch/invalid" > "$scratch/error" 2>&1; then
    echo 'invalid validation flag unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'VALIDATE_RELEASE must be true or false' "$scratch/error"
test ! -e "$scratch/invalid"
echo 'Image preparation qualification, filtering, and release validation guards passed'
