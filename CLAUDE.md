# Working on Codling

Codling is an open-source package manager for jailbroken iOS, licensed under
Apache-2.0. Burrow (github.com/Nexus-jb/burrow) is its tweak injection
platform, and Nexus (nexusjb.com) is the default source.

## Rules

- **English only.** Everything committed here is English: code, identifiers,
  comments, commit messages, branch names, pull request text, documentation and
  user interface strings. Chats with the owner may happen in another language;
  never copy chat text into this repository. `scripts/check-text-policy.py`
  enforces this in CI, and the list of accepted localizations lives there. Do
  not add localizations: only the maintainers add them.
- **Never copy code from the private Nexus repository.** Integrate with Nexus
  only through its public interfaces: the APT repository at
  `repo.nexusjb.com` and the payment provider API that Sileo and Zebra use.
- **Neutral by design.** Nexus is a default source that users can remove. Never
  rank, hide or slow down other sources, and never add ads or tracking. Crash
  reports and compatibility data leave the device only with the user's consent.
- **No dead features.** Do not ship buttons, screens or data that pretend to
  work. A feature lands when it works on a real device.
- **Licensing.** New source files start with
  `// SPDX-License-Identifier: Apache-2.0` (or `#` for scripts). Do not copy
  code from GPL projects such as Cydia, Sileo or Zebra; they are references only.
- **Never commit secrets**, signing keys or personal data.

## Layout

| Path | Contents |
| --- | --- |
| `App/` | The SwiftUI app |
| `packaging/` | Entitlements and package metadata |
| `project.yml` | XcodeGen project definition (the `.xcodeproj` is generated) |
| `scripts/package-deb.sh` | Builds the rootless and roothide `.deb` packages |
| `scripts/check-text-policy.py` | The English-only check |
| `.github/workflows/` | CI: text policy, build, packaging and attestation |

## Building

```sh
brew install xcodegen ldid dpkg
xcodegen generate
xcodebuild -project Codling.xcodeproj -target Codling -configuration Release \
  -sdk iphoneos SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO
scripts/package-deb.sh build/Release-iphoneos/Codling.app 0.1.0 dist
```

## Workflow

- Work on a branch and open a pull request; the owner merges into `main`.
- Keep each pull request to one step of the work plan, and describe how it was
  tested (device, iOS version, jailbreak).
