# Codling

A modern, open-source package manager for jailbroken iOS.

> **Status: early development.** Codling is not ready for everyday use yet.
> Version 1.0 will follow a closed and a public beta. To apply for the closed
> beta, join the [Codling Beta Discord server](https://discord.gg/Q6cNndxacQ)
> and post in #apply.

Codling installs, updates and removes packages from APT repositories on
jailbroken iPhones and iPads. It is written from scratch in Swift and SwiftUI on
top of APT and dpkg, and it works hand in hand with
[Burrow](https://github.com/Nexus-jb/burrow), our open-source tweak injection
platform.

## What Codling is built to do

The features below are the goals for version 1.0. Each one ships only when it
works on real devices.

### Keep your device working

- **Undo.** Codling records your package state before every change, so one tap
  takes you back to how things were.
- **Smart Safe Mode, with Burrow.** When a tweak crashes SpringBoard, only that
  tweak is turned off, and Codling tells you which one and why.
- **Compatibility first.** Before you install anything, Codling tells you
  whether it supports your iOS version and your jailbreak.

### Tell developers what is happening

- **Crash reports, only with your consent.** A crash caused by a tweak can be
  sent to its developer, grouped with similar crashes. Nothing leaves your
  device unless you allow it.
- **Real-world compatibility data** for each iOS version and jailbreak, opt-in
  and anonymous.
- **Piracy warnings** for sources known to redistribute paid packages.

### Be fast and clear

- Sources refresh in parallel and incrementally, into a local index.
- Errors are explained in plain language, with a **Fix** button where one
  exists, instead of raw APT output.
- **Crash reports, only with your consent.** The Burrow screen lists the
  crashes Burrow blames on a tweak. Send to Developer shows exactly what
  goes to the tweak's source before it is sent, and only sources that take
  reports receive them. Share sends a report anywhere you choose. Share Install Results, off until you turn it on,
  tells sources whether their packages installed.
  [docs/reports.md](docs/reports.md) describes the format.
- **Add to Codling buttons.** A repository's page can link to
  `codling://source/` with its address, and Codling asks before adding it.
  `codling://package/` opens a package's page.
- **Open a .deb from anywhere.** Share a `.deb` to Codling from Files,
  Safari or any other app, and it shows what the package is, warns that no
  source vouches for it, and installs it with its dependencies after the
  usual review.
- A native iOS design with full VoiceOver and Dynamic Type support. Sileo
  native depictions are drawn with the system's own fonts and colors.

## Neutral by design

Codling comes with the [Nexus](https://nexusjb.com) repository as a default
source, and you can remove it. Every source is treated the same way: no hidden
ads, no tracking and no paid placement. Purchases use the payment provider API
that other package managers already support, so paid repositories work in
Codling without extra setup.

If you run a repository, [docs/repository-owners.md](docs/repository-owners.md)
explains what Codling reads from it and what to publish.

## Supported jailbreaks

| Scheme   | Package architecture | Examples                             |
| -------- | -------------------- | ------------------------------------ |
| rootless | `iphoneos-arm64`     | Dopamine                             |
| roothide | `iphoneos-arm64e`    | Dopamine (RootHide)                  |

iOS 15 and later. Rootful jailbreaks are not planned for 1.0.

Devices with an Apple A12 chip or newer: iPhone XS, iPhone XR and later,
and the iPads with an A12 chip or newer. The package refuses to install on
older chips. The layout follows the window, from the 4.7-inch iPhone SE to
the 13-inch iPad Pro, upright and on its side;
[docs/screen-sizes.md](docs/screen-sizes.md) explains how, and how it is
checked on simulators.

## How Codling gets root

Installing packages needs root. Codling starts its helper, `codling-helper`
inside the app bundle, as root through a spawn persona, which takes an
entitlement only Codling holds. The helper has no setuid bit, so any other
program that runs it gets nothing more than it had. The helper does only the
commands it knows, takes no paths from its caller, and starts with a clean
environment. A `.deb` you open in Codling reaches it as a random token, never
as a path: Codling copies the file into its caches, and the helper takes it
from there into a directory only root can write. Its source is
[Helper/codling-helper.c](Helper/codling-helper.c).

## Building

Every push is built on GitHub Actions. Release packages are signed and carry
build provenance attestations, so you can check that a package was built from
this repository:

```sh
gh attestation verify com.nexusjb.codling_<version>_iphoneos-arm64.deb --repo Nexus-jb/codling
```

To build locally you need macOS with Xcode and Homebrew:

```sh
brew install xcodegen ldid dpkg
xcodegen generate
xcodebuild -project Codling.xcodeproj -target Codling -configuration Release \
  -sdk iphoneos SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO
scripts/package-deb.sh build/Release-iphoneos/Codling.app 0.1.0 dist
```

The packages are written to `dist/`.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first.

## Security

Please report vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).

## License

Codling is made by Ultra Team and licensed under the [Apache License 2.0](LICENSE). The names
"Codling" and "Burrow" and their logos are not covered by the license (see
[NOTICE](NOTICE)).

Codling is an independent project. It is not affiliated with or endorsed by
SaurikIT, Cydia, Sileo or Zebra.
