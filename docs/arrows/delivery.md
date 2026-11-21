# Arrow: delivery

Builds, verifies, signs, and publishes the container image and the restore-tool binaries, and keeps every input pinned and current.

## Status

**MAPPED** — 26 of 27 specs verified: pull-request checks (the comparison scan included), the main-branch scan and signed publish, and the `v1.0.0` release run have all been observed green. The release produced four tested binaries with checksums, Sigstore bundles, and SLSA provenance; the macOS arm64 asset was downloaded, verified with `gh attestation verify`, and decrypted the format fixture byte for byte. The one open spec is the weekly GHCR retention run, verified when it next fires.

## References

### HLD
- docs/high-level-design.md (System Design → delivery; Key Design Decisions 5, 6, 7)

### LLD
- docs/intent/delivery/delivery-design.md

### EARS
- docs/intent/delivery/delivery-specs.md (27 specs)

### Tests
- .github/workflows/test.yml (fmt, clippy, workspace tests, amd64 image build, `--version` smoke under default seccomp)
- .github/workflows/release.yml (restore-tool tests on every target before publishing)
- `cargo deny check` locally (advisories, licences, bans, sources)

### Code
- Dockerfile
- docker-compose.yml
- rust-toolchain.toml, deny.toml, .dockerignore
- .github/workflows/test.yml, docker-publish.yml, supply-chain.yml, release.yml, ghcr-retention.yml
- .github/release-notes.md
- renovate.json
- osv-scanner.toml

## Architecture

**Purpose:** Produce a distroless, non-root, digest-pinned, signed and attested `linux/amd64` image holding one static binary, and a signed, attested, tested restore binary for four desktop targets.

**Key Components:**
1. Dockerfile — `rust:alpine` builder (`cargo build --locked`, musl target, gcc and musl-dev already present) → Chainguard `static` runtime, UID 1000, `/app/backvault`.
2. `test.yml` — PR gate: fmt, clippy, tests, amd64 build, `--version` smoke.
3. `supply-chain.yml` — the shared scan from `chainringlabs/ci` on pull requests (comparison mode), weekly and on demand (full).
4. `docker-publish.yml` — main-branch pipeline: full scan (Socket / OSV / cargo-deny) → build → push → cosign sign → SPDX SBOM → attestations.
5. `release.yml` — tag pipeline: four-target restore-tool matrix, tests per target, checksums, cosign blob signatures, provenance, GitHub Release with `.github/release-notes.md`.
6. `ghcr-retention.yml` — weekly prune.
7. `renovate.json` + `deny.toml` — digest pinning, grouped automerge, toolchain lockstep via a custom manager, advisory and licence policy.
8. `docker-compose.yml` — reference deployment with no `security_opt`; published image name; `BW_CA_CERT` shown for self-signed servers.

## Spec Coverage

| Category | Spec IDs | Implemented | Deferred | Gaps |
|----------|----------|-------------|----------|------|
| Image build | IMAGE-BUILD-001 to 003, 005 to 008 | 7 | 0 | 0 |
| Reference deployment | IMAGE-RUN-001 to 004 | 4 | 0 | 0 |
| CI pipeline | IMAGE-CI-001 to 007 | 6 | 0 | 1 |
| Release pipeline | IMAGE-RELEASE-001 to 005 | 5 | 0 | 0 |
| Dependency policy | IMAGE-DEPS-001, 002, 004, 005 | 4 | 0 | 0 |

**Summary:** 26 of 27 active specs verified; IMAGE-CI-006 awaits the next weekly retention run. IMAGE-CI-005 (Socket self-skip without the secret) is verified by inspection of the `if:` guard: the secret is present on pushes to `main` and on the owner's pull requests; bot-authored pull requests are where the skip path is exercised. These specs are verified by inspection and by CI runs, not by unit tests.

## Key Findings

1. **The image is one file.** No interpreter, venv, or libc; the smoke test can only pass if the binary is truly static.
2. **The restore tool is tested on every platform it ships for** before a release exists.
3. **Toolchain has one version, two carriers** (`rust-toolchain.toml` and the builder image tag), kept in step by one Renovate group; the Dockerfile never lets rustup download.
4. **No `HEALTHCHECK`** — depends on scheduler-retention exposing a heartbeat.

## Work Required

### Must Fix
*(none)*

### Should Fix
1. Confirm the GHCR retention workflow prunes as before on its next weekly run (IMAGE-CI-006).

### Nice to Have
2. Pin GitHub Actions by digest (LLD Deferred 2).
3. Add a `HEALTHCHECK` once scheduler-retention exposes a heartbeat.
