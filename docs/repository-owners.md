# Codling for repository owners

What Codling reads from an APT repository, and what to publish so that your
packages show and install well. Codling installs everything through apt, so
a repository that works with apt works with Codling; the rest of this guide
is about what Codling shows and checks on top.

## What Codling fetches

For each source, Codling fetches the Release file, then the package index it
lists:

1. `InRelease`. If there is none, `Release` and then `Release.gpg`.
2. The index: `Packages` at the top of a flat repository, or
   `dists/<suite>/<component>/binary-<architecture>/Packages` in a repository
   with suites.

Codling picks the first form of the index that the Release file lists:
`.xz`, then `.bz2`, then `.gz`, then uncompressed. It checks the download
against the strongest checksum the Release file gives for it: SHA512,
SHA256, SHA1, then MD5Sum. It also checks the size. A mismatch fails the
refresh with a message that names the file. Without a Release file, or one
without checksums, Codling tries the same forms in the same order. It warns
the user that the index cannot be checked.

An index may be at most 512 MiB once decompressed.

Every request carries:

| Header | Value |
| --- | --- |
| `User-Agent` | `Codling/<version> (<model>; iOS <version>)`, such as `Codling/0.1.0 (iPhone15,3; iOS 16.3.1)` |
| `X-Machine` | The model, such as `iPhone15,3` |
| `X-Firmware` | The iOS version, such as `16.3.1` |
| `Accept-Encoding` | `identity`: checksums are of the file as you publish it |

Codling sends no UDID to repositories. It sends `If-None-Match` and
`If-Modified-Since` with the Release file. Answer `304 Not Modified` when
nothing changed, and Codling skips the rest of the refresh. When the Release
file changed but the checksums of the index did not, Codling does not
download the index again.

## Signing

Sign your Release file. Codling checks the signature with `gpgv`, against the
keys apt trusts on the device: the source's `Signed-By` keyring, or else
every keyring in `trusted.gpg.d` and `trusted.gpg`. A source's page shows
the result under Security Check:

- **Signed by your key**, when the signature is good and the key is trusted.
- **Signed with a key this device does not trust**, when the key is not
  installed. Ship your key in a package (a keyring in
  `/var/jb/etc/apt/trusted.gpg.d`) for users who want to trust it.
- **Not signed.**
- A bad signature fails the refresh: the Release file may have been changed
  on the way.

apt makes the same check when it installs. A package from a source apt
cannot verify needs the user's confirmation, "Install Without
Verification", on every install. That includes paid packages.

## Architectures

Codling reads the packages for the device's architecture and `all`:

| Jailbreak | Architecture |
| --- | --- |
| Rootless (Dopamine) | `iphoneos-arm64` |
| RootHide (Dopamine) | `iphoneos-arm64e` |

Rootful jailbreaks are not supported, so `iphoneos-arm` packages are not
shown.

## Package fields

Codling reads these fields from your index. Field names are matched without
regard to case.

| Field | What Codling does with it |
| --- | --- |
| `Package`, `Version` | Required. A stanza without them is skipped. |
| `Architecture` | See above. |
| `Name` | The name shown. Without it, the package identifier. |
| `Description` | The first line is the summary under the name. The whole description is on the package page when there is no depiction, or when it cannot load. |
| `Section` | The category, used to browse. |
| `Author`, `Maintainer` | The developer shown is `Author`, or `Maintainer` without it, without the email address. |
| `Icon` | An `http` or `https` address, or one relative to the repository. |
| `SileoDepiction` | A native depiction (below). |
| `Depiction` | A web depiction. When it ends in `.json`, it is read as a native depiction. |
| `Depends` | Read by apt. Codling also reads `firmware` in it to tell whether the package supports the device's iOS. |
| `Tag` | `cydia::commercial` marks a paid package. `compatible::ios16`, `compatible_min::ios15` and `compatible_max::ios17.4` state supported iOS versions. |
| `Filename`, `Size`, `SHA256` | Read by apt to download and check the package. Codling also checks a paid package's download against `SHA256`. |

### Supported iOS versions

Codling marks a package as supported, unsupported or unknown on the device's
iOS. It reads, in this order:

1. a `firmware` dependency, which apt enforces, such as
   `firmware (>= 15.0), firmware (<< 18.0)`;
2. the `compatible` tags;
3. the name and summary, such as "Glow (iOS 15-17)".

A dependency with only a minimum, and a maximum in the name or the tags,
counts as both. Put both bounds in `Depends` when you know them.

## Repository files

Codling looks for these beside the Release file, then at the top of the
repository:

| File | Use |
| --- | --- |
| `CydiaIcon.png` | The source's icon. |
| `sileo-featured.json` | Banners on the Featured tab, in Sileo's format. At most 30 per source. Each banner needs `url` (its image); `title`, `package` and `hideShadow` are optional. `itemSize` and `itemCornerRadius` apply to all of them. |
| `payment_endpoint` | Your payment provider, for paid packages (below). |

## Depictions

### Native depictions

A native depiction is JSON in Sileo's format. Codling draws it with its own
views. Prefer it: it opens faster than a web page, and it follows the
user's text size, dark mode and accessibility settings.

Codling draws these classes:

- Pages: `DepictionTabView`, `DepictionStackView`, `DepictionAutoStackView`
  and `DepictionLayerView`.
- Text: `DepictionHeaderView`, `DepictionSubheaderView`, `DepictionLabelView`,
  `DepictionMarkdownView` and `DepictionTableTextView`.
- Buttons: `DepictionTableButtonView` and `DepictionButtonView`.
- Media: `DepictionScreenshotsView`, `DepictionImageView`, `DepictionVideoView`
  and `DepictionWebView`.
- Layout: `DepictionSeparatorView` and `DepictionSpacerView`.
- Ratings: `DepictionRatingView` and `DepictionReviewView`.

`headerImage`, `tintColor` and `backgroundColor` apply at the root. Any other
class, including `DepictionAdmobView`, is left out: Codling shows no ads.

Links and buttons may open:

- `http` and `https` pages;
- another native depiction, with `depiction-<address>`;
- a package, with `sileo://package/<identifier>`, `cydia://package/<identifier>`
  or `zbra://packages/<identifier>`;
- `mailto:`, `tel:` and `sms:` addresses.

Anything else does nothing, so put the button's fallback in `backupAction`.
Relative addresses are resolved against the depiction's address.

### Web depictions

Codling shows a web depiction inside the package page, in a private web
session. The page loads with `Accept-Language: en`, and `Codling` is added to
the browser's user agent. A link the user taps opens as a page of its own in
Codling. A page cannot open windows by itself, and it can load only `http`,
`https`, `about`, `data` and `blob` addresses. A page that answers 400 or
above shows an error instead.

## Paid packages

Codling uses the payment provider API that Sileo documents and Sileo and
Zebra use. If your packages sell in those, they sell in Codling without
changes. Mark each paid package with `cydia::commercial` in `Tag`, and
publish your provider's address in `payment_endpoint`:

- The file holds one HTTPS address. Codling reads it over HTTPS only. For a
  repository served over HTTP, it asks for the same address over HTTPS.
- Codling uses `info`, `authenticate` (returning to
  `sileo://authentication_success`), `user_info`, `sign_out`, and
  `package/<identifier>/` `info`, `purchase` and `authorize_download`.
- Signed out, Codling asks `package/<identifier>/info` with a GET and sends
  nothing about the device. Signed in, it asks with a POST that carries the
  token, the UDID and the model.
- `authorize_download` gets `token`, `udid`, `device`, `version`, `repo` and
  `architecture`. `architecture` is the `Architecture` of the record, so a
  provider with separate builds for rootless and RootHide can send the
  right one.
- Checkout and download addresses must be HTTPS. Provider requests do not
  follow a redirect to HTTP.
- The download must match the `SHA256` your index lists for that version.
  apt installs it after the same signature check as any other package.

Codling keeps each sign-in in the device's Keychain, per provider. The
payment secret is kept behind Face ID, Touch ID or the passcode.

## Sources Codling warns about

Codling keeps a short list of sources that published articles describe as
handing out paid packages without their developers' permission. It warns
before one is added and marks one that is there. It never blocks, hides or
slows a source. [piracy-sources.md](piracy-sources.md) gives the evidence
for each entry and explains how to propose or contest one.
