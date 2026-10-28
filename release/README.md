# Unified data image builds

The image provides generated runtime catalogs at `/app/data` and benchmark
data at `/app/benchmarks`. Only catalogs listed in `runtime-catalog-files.txt`
are shipped. Catalog indexes, `input/`, credentials, reports, Git metadata,
and build tools stay outside the runtime image.

## Required serving-runtime catalog

RHOAI 3.6 configures the serving-runtime source at
`/app/data/redhat-serving-runtimes-catalog.yaml`. Every build requires this file
and the other consumer catalogs independently of the packaging allowlist, so
removing a catalog from both the list and `data/` fails before packaging.
The preparation stage also regenerates the serving-runtime catalog in memory,
checks it against the committed bytes, and validates its pinned model-registry
API schemas. These offline checks run even when `VALIDATE_RELEASE=false`.
They verify content and source references; a real versioned consumer check
remains necessary for release qualification.

Run `make check-serving-runtimes` to perform these checks locally. See
[`input/serving_runtimes/README.md`](../input/serving_runtimes/README.md) for
provenance and the offline update workflow. Only the generated catalog ships;
the index, runtime inputs, schemas, and generator stay in the build stage.

## Default build

`Dockerfile` defaults to `VALIDATE_RELEASE=false`. It fetches the private
`https://github.com/red-hat-data-services/models-perf-benchmark-data.git`
repository at the immutable `BENCHMARK_REVISION` pinned in the Dockerfile and
runs `api-client/qualify.py --mode test` against an immutable catalog commit.
Only the resulting filtered `benchmarks/` handoff is packaged. It needs no local
benchmark files, approval report, or loader scripts.

```sh
make docker-build
```

Make obtains Git credentials from `GITHUB_TOKEN_FILE`, the `GITHUB_TOKEN`
environment variable, or an existing `gh` login, in that order. Only read
access to the benchmark and selected catalog repositories is needed. The token
is a build secret; do not put it in a build argument or repository URL.

Make defaults `CATALOG_REVISION` to the current Git commit and
`CATALOG_DATA_REPOSITORY` to the upstream catalog repository. Use your fork URL
when the commit exists only there. The build fetches that commit and compares
its runtime catalog bytes with the build context before qualification.

For direct Docker or Podman builds, supply the catalog revision and secret
(and `CATALOG_DATA_REPOSITORY` when using a fork):

```sh
docker build \
  --build-arg CATALOG_REVISION=<full-catalog-commit-sha> \
  --secret id=github_token,env=GITHUB_TOKEN \
  -t ai-hub-catalog:local .
```

The default runtime base requires registry.redhat.io credentials. Local tests
can override it with
`BASE_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal@sha256:a21d19f72557aa893a0f6ca1177bb1ffd91df6015e60470a116c50a6a05efcd9`
(a Make variable or `--build-arg` for Docker/Podman).

The normal build applies the producer's `approved-for-testing` exclusion
policy. With the current benchmark pin and catalog, the source has 131 models;
qualification includes 103 and excludes the 28 unmatched models. Qualification
rejects new mismatches and stale exclusions, and any failure stops the build.
The test-qualified handoff is marked `promotion_eligible: false`.

Consumer release validation and RHOAI loader scripts remain opt-in. The build
checks the image layout and makes payload files read-only and readable by
arbitrary non-root users. The label `io.openshift.ai.release-validation=false`
records that release validation did not run. Default images are not eligible
for release promotion.
Private benchmark data must never be committed to this repository.

## Opt-in release validation

Set `VALIDATE_RELEASE=true` to run the existing release checks:

```sh
make docker-build \
  VALIDATE_RELEASE=true \
  BENCHMARK_REVISION=<full-release-approved-benchmark-commit-sha> \
  MODEL_CATALOG_LOADER_CHECK_DIR=/path/to/supported-version-checks
```

This switches the upstream qualifier to `--mode release`, validates its handoff
with the consumer validator, and runs the RHOAI loader checks. Both modes fetch
the selected catalog commit and verify it matches the build context.

Make automatically adds `--no-cache` when `VALIDATE_RELEASE=true`. Loader
scripts are build secrets, whose contents do not invalidate cached layers;
disabling the cache ensures each validated build runs the supplied checks.
Direct Docker/Podman builds must also use `--no-cache`:

```sh
docker build --no-cache \
  --build-arg VALIDATE_RELEASE=true \
  --build-arg BENCHMARK_REVISION=<full-release-approved-benchmark-commit-sha> \
  --build-arg CATALOG_REVISION=<full-catalog-commit-sha> \
  --secret id=github_token,env=GITHUB_TOKEN \
  --secret id=rhoai-3.6,src=/path/to/supported-version-checks/rhoai-3.6 \
  -t ai-hub-catalog:validated .
```

Approval must be `approved`, qualification mode `release`, and the report
promotion-eligible. The pinned benchmark commit currently has
`approved-for-testing`, so enabling validation rejects it. Neither this build
switch nor advisory CI grants release approval.

Both modes package the producer's qualified handoff, including its regenerated
manifest. Neither mode copies the unfiltered benchmark source into the image.

The image ships only for RHOAI 3.6 and later, so the only loader executable is
`rhoai-3.6`. It must use the matching Model Catalog consumer, load both payloads, assert their records,
and print `MODEL_CATALOG_LOADER_CHECK_OK=<version>` only after success. It
receives `MODEL_CATALOG_VERSION`, `RELEASE_CANDIDATE_ROOT`, `CATALOG_DATA_DIR`,
and `BENCHMARK_DATA_DIR`. Its dependencies must exist in the preparation
image; `BUILDER_IMAGE` can select a reviewed builder with the required tooling.
The RHOAI 3.6 runner must also load the serving-runtime catalog and assert its
runtime and version records. A runner that only loads model metadata cannot
prove this requirement. The repository does not provide these product-version
runners; fixture checks are not substitutes for them.

Consumer validation verifies syntax, identities, references, catalog/benchmark
compatibility, report hashes and model membership, manifests, safe paths,
staged bytes, and file permissions. It detects loader modifications to the
payload. Matching uses complete model IDs case-insensitively, without aliases.
Metric-specific schemas remain a producer/consumer contract.

Standalone validation of an existing qualified handoff remains available:

```sh
make validate-release-candidate \
  BENCHMARK_DATA_DIR=/path/to/handoff/benchmarks \
  BENCHMARK_QUALIFICATION_REPORT=/path/to/handoff/qualification-report.json \
  MODEL_CATALOG_LOADER_CHECK_DIR=/path/to/supported-version-checks
```

This stages `build/release-candidate/app` for inspection; the Dockerfile does
not consume that host directory. The synthetic fixture targets and
`Dockerfile.fixture` remain separate public CI checks. The CLI also retains
its explicit test-qualification options for standalone diagnostics.

## Advisory GitHub CI

`build-and-push-static-model-catalog-data.yml` has an independent
**Release validation (advisory)** job. It calls
`make docker-build VALIDATE_RELEASE=true` with job-level
`continue-on-error: true`, records the outcome in the job summary, and does not
publish an image. A failed check does not fail the workflow. Keep this advisory
job out of required branch checks until the team decides to make it blocking.

Configure these repository secrets to run it:

| Secret | Value |
| --- | --- |
| `BENCHMARK_GITHUB_TOKEN` | Token with read access to the benchmark and selected catalog repositories |
| `RHOAI_3_6_LOADER_CHECK` | Contents of the reviewed RHOAI 3.6 executable script, including serving-runtime loading |

Optional repository variables are `BENCHMARK_REVISION` (otherwise use the
Dockerfile pin) and `RELEASE_VALIDATION_BUILDER_IMAGE` (builder with loader
dependencies). CI selects the PR head commit and its repository for catalog
qualification, rather than an ephemeral merge commit.

Missing secrets are reported as unavailable inputs, not as a successful
validation. Fork PRs normally do not receive these secrets. The job uses the
standard `pull_request` event; it does not elevate fork access. Unit tests and
the public fixture image job remain independent of this advisory check.

## Konflux handoff

Select `Dockerfile` with build context `.`. Supply `CATALOG_REVISION` matching
the build context and `CATALOG_DATA_REPOSITORY` when using a fork. Default
builds need no release validation flags or loader scripts. The benchmark SHA
is already pinned; override `BENCHMARK_REVISION` only when selecting a
different commit.
The default fetch still requires a `github_token` build secret under
`/run/secrets/github_token` and registry access to the selected base image.
Pipeline checkout credentials alone do not expose that secret inside a build.

The current preparation stage also downloads RPM, Python, and Go dependencies.
Configure the required network access or adapt prefetch and builder tooling
before using a hermetic pipeline. Local checks cover x86_64; validate other
requested architectures in Konflux.

When enabling release validation, supply `VALIDATE_RELEASE=true`, the catalog
revision/repository, a release-approved benchmark revision, and the loader
secret as described above, and disable
the build cache (`--no-cache`) so loader checks execute on every build. Regenerate
generated `.tekton` files through their owning product-management configuration;
this change does not edit them. The current generated pipelines still use
`VALIDATE_RELEASE=false`: they now enforce the required catalog and offline
serving-runtime checks through `Dockerfile`, but do not prove RHOAI 3.6 consumer
loading or release eligibility. Before enabling the release gate, provision the
runner secret and dependencies, configure secret mounts and cache
invalidation in the owning PMT pipeline, and select release-approved benchmarks. `Dockerfile.konflux` retains its existing
catalog-only behavior until that pipeline configuration selects `Dockerfile`.
