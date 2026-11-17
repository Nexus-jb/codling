# Security Policy

Codling installs software with root privileges through a small helper, so we
treat security reports as a priority.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Report it privately through GitHub: open the **Security** tab of this
repository and choose **Report a vulnerability**. Include the Codling version,
your iOS version and jailbreak, and the steps to reproduce the problem.

We will confirm that we received your report, keep you informed while we work
on a fix, and credit you in the release notes unless you prefer otherwise.

## In scope

- The Codling app and its privileged helper
- URL scheme and deep link handling
- Sign-in and payment flows
- Repository signature verification and package downloads
- Release packages and the build pipeline

## Verifying a release

Every release package comes with a build provenance attestation. Check it
before you install a package from anywhere other than an official repository:

```sh
gh attestation verify <package>.deb --repo Nexus-jb/codling
```
