# Codling

A modern, open-source package manager for jailbroken iOS.

> **Status: early development.** Codling is not ready for everyday use yet.
> Version 1.0 will follow a closed and a public beta.

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
- A native iOS design with full VoiceOver and Dynamic Type support.

## Neutral by design

Codling comes with the [Nexus](https://nexusjb.com) repository as a default
source, and you can remove it. Every source is treated the same way: no hidden
ads, no tracking and no paid placement. Purchases use the payment provider API
that other package managers already support, so paid repositories work in
Codling without extra setup.

## Supported jailbreaks

| Scheme   | Package architecture | Examples                             |
| -------- | -------------------- | ------------------------------------ |
| rootless | `iphoneos-arm64`     | Dopamine, palera1n (rootless mode)   |
| roothide | `iphoneos-arm64e`    | Dopamine (RootHide)                  |

iOS 15 and later. Rootful jailbreaks are not planned for 1.0.

## Building

Every push is built on GitHub Actions. Release packages are signed and carry
build provenance attestations, so you can check that a package was built from
this repository:

```sh
gh attestation verify com.nexusjb.codling_<version>_iphoneos-arm64.deb --repo Nexus-jb/codling
```

Instructions for building locally will be added with the app skeleton.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
first.

## Security

Please report vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md).

## License

Codling is licensed under the [Apache License 2.0](LICENSE). The names
"Codling" and "Burrow" and their logos are not covered by the license (see
[NOTICE](NOTICE)).

Codling is an independent project. It is not affiliated with or endorsed by
SaurikIT, Cydia, Sileo or Zebra.
