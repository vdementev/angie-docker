# Security policy

## Reporting a vulnerability

Please report privately rather than opening a public issue.

- [GitHub private vulnerability reporting](https://github.com/vdementev/angie-docker/security/advisories/new) (preferred)
- `security@lotuswebagency.com`

Useful in a report: the tag or digest you found it in, the CVE or a
reproduction, and what an attacker gets out of it. If you have a fix, a pull
request is welcome, but send the report first.

## Response targets

Business days, Asia/Bangkok.

| Stage | Target |
|---|---|
| Acknowledgement | 2 business days |
| Triage and severity call | 5 business days |
| Published fix — fixable CRITICAL or HIGH | 7 days from triage |
| Published fix — everything else | the next weekly rebuild |

Fixes ship as a rebuild of the current tags, so `docker pull` is the upgrade
path. Tag lifecycle and rebuild cadence are described in [SUPPORT.md](SUPPORT.md).

## What is already automated

Every build — pull request, merge, or the weekly rebuild — runs a Trivy scan and
fails on any *fixable* CRITICAL or HIGH finding before the image can be
published, so a known-vulnerable image cannot ship silently. `main` is
branch-protected: publishing requires a green pull request. Published digests
carry an SBOM, max-mode SLSA provenance and a keyless Cosign signature, all
produced by the shared pipeline in
[vdementev/docker-workflows](https://github.com/vdementev/docker-workflows).

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'github.com/vdementev/' \
  dementev/angie:latest
```

Findings that are accepted rather than fixed (no upstream fix available, or not
reachable in this image) are recorded in a `.trivyignore` file in this
repository together with the reason, so the gate stays meaningful instead
of being switched off.

## Scope

In scope: anything shipped from this repository, and anything in a published
`dementev/angie` image.

Out of scope: vulnerabilities in upstream projects that we only package — report
those upstream, and tell us so we can pin or patch around them; findings that
require an already-compromised host or Docker daemon; and unfixable CVEs already
listed in `.trivyignore` with a reason.
