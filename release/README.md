# Unified data image inputs

The release candidate contains two runtime payloads:

- the generated catalog files listed in `runtime-catalog-files.txt`, installed at `/app/data`;
- the qualified private benchmark handoff, installed at `/app/benchmarks`.

Catalog indexes, files under `input/`, generator binaries, reports, credentials, and the benchmark producer are producer-only inputs. They are validated where applicable but are not copied into the runtime image. The existing models catalog remains in the runtime allowlist to preserve the current image contract.

`Dockerfile` fetches
`https://github.com/red-hat-data-services/models-perf-benchmark-data.git`
at `BENCHMARK_REVISION` inside its preparation stage. It runs that repository's
`api-client/qualify.py --mode release` against the catalog at
`CATALOG_REVISION`, then runs the consumer validator and supported-version
loader checks. Only the validated payload is copied into the runtime image.
The qualifier generates the handoff and report during the build; no local
benchmark checkout, report, or staged payload is required. Private benchmark
data must never be committed to this repository.

Build with full immutable commit SHAs, using a benchmark revision that contains
the producer qualifier and release-approved exclusion policy:

```sh
make docker-build \
  BENCHMARK_REVISION=<full-approved-benchmark-commit-sha> \
  MODEL_CATALOG_LOADER_CHECK_DIR=/path/to/supported-version-checks
```

Make defaults `CATALOG_REVISION` to the local Git commit and
`CATALOG_DATA_REPOSITORY` to the upstream catalog repository. The commit must
already be available remotely; use your fork's HTTPS URL when needed. The
build compares the context's runtime catalog files with that commit before
qualification. `BENCHMARK_DATA_REPOSITORY` can also override the benchmark URL.

Make supplies private Git access using `GITHUB_TOKEN_FILE`, the `GITHUB_TOKEN`
environment variable, or the token from an existing `gh` login, in that order.
The token must have read access to both repositories. Credentials are passed
as a build secret, never as a build argument or part of a repository URL.
Git checkouts are temporary and are removed before the preparation layer is
saved. Direct Docker builds use the same contract:

```sh
docker build \
  --build-arg BENCHMARK_REVISION=<full-approved-benchmark-commit-sha> \
  --build-arg CATALOG_REVISION=<full-catalog-commit-sha> \
  --secret id=github_token,env=GITHUB_TOKEN \
  --secret id=rhoai-3.4,src=/path/to/supported-version-checks/rhoai-3.4 \
  --secret id=rhoai-3.5,src=/path/to/supported-version-checks/rhoai-3.5 \
  -t model-metadata-collection:latest .
```

Loader executables run inside the preparation stage. Their dependencies must
be present there; `BUILDER_IMAGE` can select a reviewed builder containing the
matching Model Catalog tooling. Loader scripts are mounted as secrets and
are not retained in the image layers.

The generated payload and qualification report form the producer/consumer
handoff boundary. The report remains outside the runtime payload. Product validation
requires content-owner approval in that report and verifies its payload digest,
manifest digest, included model IDs, source revisions, and exact catalog file
hashes before staging either payload. The report must be produced in release
mode and explicitly marked as eligible for promotion. The build cannot grant
approval: it rejects an upstream policy marked `approved-for-testing`.
Product mode refuses the committed fixture payload, report, loader, and version list.

For standalone validation of an existing qualified handoff, use:

```sh
make validate-release-candidate \
  BENCHMARK_DATA_DIR=/path/to/handoff/benchmarks \
  BENCHMARK_QUALIFICATION_REPORT=/path/to/handoff/qualification-report.json \
  MODEL_CATALOG_LOADER_CHECK_DIR=/path/to/supported-version-checks
```

This command stages `build/release-candidate/app` for inspection. The product
Dockerfile does not consume that host directory. Public CI retains its
synthetic fixture validation and uses `Dockerfile.fixture` to package
`build/release-candidate-fixture/app`. Make fixes these standalone/fixture
output paths; the underlying CLI accepts an arbitrary `--output-dir`.

For standalone validation, the loader-check directory must contain exactly one executable per entry in
`supported-model-catalog-versions.txt`, named for that version, with no missing
or extra files. The dual-payload compatibility matrix contains RHOAI 3.4 and
3.5. RHOAI 2.25 is catalog-only because its Model Catalog implementation has no
benchmark-loading option; the generic release validation still checks that the
benchmark payload is present, qualified, and compatible with the catalog.
Each executable receives
`MODEL_CATALOG_VERSION`, `RELEASE_CANDIDATE_ROOT`, `CATALOG_DATA_DIR`, and
`BENCHMARK_DATA_DIR`, must recursively initialize and load the candidate, and
only then print `MODEL_CATALOG_LOADER_CHECK_OK=<version>`. The release command
fails when membership differs, an entry is not executable, a check fails, or
the attestation is absent. The release owner supplies and reviews the matching
product-version executables; they are intentionally not mocked in this data
repository. `make validate-release-candidate-fixture` uses an isolated synthetic
payload, version list, and behavior-checking loader; its CLI guard accepts only
those committed fixture paths and a separate `build/release-candidate-fixture`
output.

Each product loader check must use the Model Catalog operand pinned by the exact
released operator bundle under test, generate that release's catalog source
configuration against the staged `/app/data` files, load `/app/benchmarks`, and
assert the expected catalog and benchmark records through the consumer. Server
startup or readiness alone is not a successful compatibility check.

Validation rejects malformed YAML, JSON, and NDJSON (including duplicate
mapping/object keys); duplicate catalog, provider, model, and benchmark artifact
identifiers; missing or escaping producer references; index/catalog
inconsistency, including agent path-to-repository URL drift; manifest/file
mismatches; qualification-report mismatches; missing provider or variant-group
references; unexpected benchmark files; benchmark records stored under the
wrong model path; catalog-to-benchmark incompatibility; symlinks; unsafe or
overlapping paths; and a staged tree that is not readable by an arbitrary
non-root user. The image is staged from the exact bytes that were validated,
and loader hooks are prevented from changing them. Catalog-to-benchmark matching
compares the complete namespace and model name case-insensitively; it does not
guess aliases or ignore spelling and punctuation differences.

The validator enforces syntax, identity, reference, and generic record-path
contracts for evaluation, performance, and security NDJSON. Metric-specific
field schemas and semantic ranges are not defined in this repository; that
remains an explicit producer/consumer contract to approve rather than a schema
invented by this release gate.

## Konflux handoff boundary

`Dockerfile` fetches and validates the unified payload during the build.
`Dockerfile.konflux` intentionally retains the current catalog-only behavior
so RHOAIENG-97415 can merge without breaking
existing Konflux pull-request and push builds. RHOAIENG-97416 must atomically
switch the product path to the unified Dockerfile contract after it wires the
immutable source revisions, Git authentication and loader-check secrets, and
relevant path triggers in
`aipcc-product-management-configs`. Do not edit generated `.tekton` files
directly.

Release promotion, stable tags, ImageStreams, registry publication, provenance, and rollback metadata belong to the follow-up release-configuration story.

The digest-pinned UBI candidate base in `Dockerfile` is reused from the current
downstream benchmark component. Productization approval for using that digest
in this unified component is required before promotion.
