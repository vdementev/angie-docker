# Support and lifecycle

## Tags

| Tag | Contents |
|---|---|
| `latest` | The newest build. Moves on every merge to `main` and on the weekly rebuild. |
| `1.12.1` | The exact Angie version inside the image. Republished in place (new digest, same tag) while that version is current. |
| `1.12` | The newest patch release of that Angie minor. |

Version tags are read out of the image after it is built and tested, so a tag
can never claim a version the image does not actually run.

Architectures: `linux/amd64`, `linux/arm64`.

## What "supported" means

A tag is supported while it is being rebuilt. `latest` and the current version
tags are rebuilt weekly (Monday, ~03:10 UTC) so they pick up base-image and
package security updates without anyone filing a bump. Older version tags stay
pullable but are frozen: no rebuilds, no CVE fixes.

Angie ships roughly quarterly from
[download.angie.software](https://download.angie.software/), and this image
follows that repository rather than Debian's, so a new Angie release lands in
`latest` on the next rebuild and gets its own version tags.

The Debian base is tracked by release (`debian:13-slim`). A move to the next
Debian release is a deliberate commit, not something a rebuild does on its own —
the apt repository URL is derived from `/etc/os-release`, so the bump is one
line in the Dockerfile plus a full test run.

## Pinning

Pin the digest, not the tag:

```dockerfile
FROM dementev/angie:1.12@sha256:...
```

That gives you a byte-identical base until you choose to move, while the tag in
front of it still says what it is. Renovate and Dependabot both understand this
form and will open a pull request when the digest changes.

## Patch cadence

| Trigger | What happens |
|---|---|
| Merge to `main` | Full build, `tests.sh`, Trivy gate, publish, sign |
| Weekly cron | Same pipeline, no source change — picks up upstream package updates |
| Fixable CRITICAL/HIGH CVE | The build fails and nothing is published until it is fixed or explicitly accepted in `.trivyignore` |

The Angie repository signing key is pinned by SHA-256 in the Dockerfile
(`ANGIE_SIGNING_SHA256`). A rotated or swapped key fails the build rather than
signing whatever it likes; bumping it is a reviewed commit.

## Breaking changes

The entrypoint contract — `FILE_FOR_GROUP`, `DOCKER_GROUP_NAME`, `ANGIE_USER`,
`ANGIE_WORKER_PROCESSES`, `ANGIE_DROP_MASTER`, the watchdog switches — and the
shipped `angie.conf` are treated as a public interface. Changes to either are
called out in the pull request and the release notes, and land with coverage in
`tests.sh`.

## Getting help

Open an issue at
[github.com/vdementev/angie-docker/issues](https://github.com/vdementev/angie-docker/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
