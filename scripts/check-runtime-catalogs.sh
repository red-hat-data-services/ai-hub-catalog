#!/bin/sh
# Required consumer files are checked independently of the packaging allowlist:
# removing a file from both data/ and the list must still fail every image build.
set -eu
catalog_dir=${1:-data}
runtime_files=${2:-release/runtime-catalog-files.txt}
for required in models-catalog.yaml validated-models-catalog.yaml other-models-catalog.yaml \
    redhat-mcp-servers-catalog.yaml partner-mcp-servers-catalog.yaml \
    community-mcp-servers-catalog.yaml redhat-agents-catalog.yaml \
    redhat-serving-runtimes-catalog.yaml; do
    if ! grep -Fxq "$required" "$runtime_files"; then
        echo "Required runtime catalog $required is missing from $runtime_files" >&2
        exit 1
    fi
done
while IFS= read -r file; do
    case "$file" in ''|\#*) continue ;; esac
    case "$file" in
        */*|*-index.yaml) echo "Invalid runtime catalog entry: $file" >&2; exit 1 ;;
        *-catalog.yaml) ;;
        *) echo "Invalid runtime catalog entry: $file" >&2; exit 1 ;;
    esac
    if [ ! -f "$catalog_dir/$file" ] || [ ! -s "$catalog_dir/$file" ]; then
        echo "Required runtime catalog $catalog_dir/$file is missing or empty" >&2
        exit 1
    fi
done < "$runtime_files"
