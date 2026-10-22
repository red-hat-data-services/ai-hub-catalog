# Serving-runtime catalog inputs

The initial 24 runtimes and 24 versions, their index, input template, offline
regeneration logic, and schema validation were imported from
[`model-metadata-collection` at `c5e6c0686758800799383b78a958a02c2a70d428`](https://github.com/opendatahub-io/model-metadata-collection/tree/c5e6c0686758800799383b78a958a02c2a70d428).
The input and generated catalog bytes are unchanged from that revision.
The schema fragments have their own upstream revision, checksums, and license
in [`internal/servingruntime/serving_runtime_schema/README.md`](../../internal/servingruntime/serving_runtime_schema/README.md).

`data/redhat-serving-runtimes-index.yaml` names each runtime and its input under
`generated/redhat/`. These inputs contain the reviewed metadata, versioned image
references, and YAML manifest objects. The generator serializes manifest objects
to the JSON strings required by the consumer and sorts runtimes and versions.

To update an existing runtime, edit its input; for a new runtime, start with
`runtime-template.yaml` and add its path and name to the index. Then run:

```sh
make process-serving-runtimes
make check-serving-runtimes
```

Review and commit the input, index, and generated catalog together. The check
rejects missing inputs, mismatched names, invalid fields or manifests, and stale
catalog bytes. It works offline and needs no registry credentials or external
CLI tools. To refresh from controller images instead, use the source repository's
online generator and synchronize its reviewed input/index/catalog together;
image discovery and SBOM resolution are intentionally maintained there.

The pinned API schema check does not prove that Kubernetes accepts the manifests
or that a specific RHOAI consumer loads them. `minimumRHOAIVersion` is currently
a catalog extension, not an API-enforced deployment restriction. Release builds
must run the real versioned consumer checks described in
[`release/README.md`](../../release/README.md).
