# syntax=docker/dockerfile:1
ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/go-toolset@sha256:8648cd4d48e09e8cef8ad031aabc34953c264990697fe9535b9c3392f83c86b0
# The candidate base is immutable so rebuilding cannot silently change its
# operating-system contents. This digest is reused from the current downstream
# benchmark image; productization must approve it for the unified component.
ARG BASE_IMAGE=registry.redhat.io/ubi9/ubi-minimal-pqc@sha256:8a842ac769de709143e4edeace516f2008dfdc431b64670ad3353fa323b44736

FROM ${BUILDER_IMAGE} AS prepare
USER 0
RUN dnf install -y git-core python3.12 python3.12-pip && dnf clean all && \
    python3.12 -m pip install --no-cache-dir PyYAML==6.0.3
WORKDIR /workspace
COPY go.mod go.sum ./
COPY cmd/release-candidate/ cmd/release-candidate/
COPY internal/releasecandidate/ internal/releasecandidate/
RUN CGO_ENABLED=0 go build -o /usr/local/bin/release-candidate ./cmd/release-candidate
COPY data/ data/
COPY input/ input/
COPY release/ release/
COPY scripts/prepare-image.sh scripts/prepare-image.sh

# Only immutable revisions are accepted. No benchmark data or pre-staged
# build/release-candidate directory is needed in the local build context.
ARG BENCHMARK_DATA_REPOSITORY=https://github.com/red-hat-data-services/models-perf-benchmark-data.git
ARG BENCHMARK_REVISION
ARG CATALOG_DATA_REPOSITORY=https://github.com/red-hat-data-services/ai-hub-catalog.git
ARG CATALOG_REVISION
RUN --mount=type=secret,id=github_token \
    --mount=type=secret,id=rhoai-3.4 \
    --mount=type=secret,id=rhoai-3.5 \
    sh scripts/prepare-image.sh /prepared

FROM ${BASE_IMAGE}
# The preceding stage fetches, qualifies, validates, and stages these bytes.
# Git metadata, credentials, reports, and build tools stay out of this image.
COPY --from=prepare --chown=1001:0 /prepared/app/ /app/

# Fail closed if either payload is absent or a producer-only catalog index
# reaches the image. OpenShift may assign any non-root UID, so every payload
# entry is world-readable and every directory is traversable.
RUN test -d /app/data && \
    test -d /app/benchmarks && \
    test -s /app/benchmarks/manifest.json && \
    /bin/sh -c 'for file in /app/data/*; do \
      test -f "${file}" || exit 1; \
      case "${file}" in *-catalog.yaml) ;; *) echo "unexpected runtime catalog file: ${file}" >&2; exit 1;; esac; \
    done' && \
    chmod -R a-w,a+rX /app

USER 1001
WORKDIR /app
VOLUME ["/app/data", "/app/benchmarks"]
CMD ["sleep", "infinity"]

LABEL name="ai-hub-catalog" \
      version="2.0" \
      description="Validated Model Catalog and qualified benchmark runtime data" \
      io.k8s.description="Provides validated Model Catalog and qualified benchmark data" \
      io.k8s.display-name="Model Catalog Data" \
      io.openshift.tags="ai,models,metadata,catalog,benchmarks"
