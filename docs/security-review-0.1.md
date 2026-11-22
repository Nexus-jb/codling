# Security review: Codling 0.1

Step 35 of the work plan, 2026-11-21. This review covers the root helper,
the links Codling opens, payments and signature checking, as of `main` at
98c39a5 (after step 29). Every finding rated Medium or higher is fixed in
the same pull request. So are the low ones, except where the table says
otherwise.

## What an attacker can reach

Codling runs as `mobile` outside the sandbox, and it holds
`com.apple.private.persona-mgmt`, which lets it start `codling-helper` as root.
The helper has no setuid bit, so another program that runs it gets nothing.
Anything that makes Codling run the helper with arguments of the attacker's
choice therefore reaches root. The inputs that can do that are:

- what sources serve: indexes, Release files, depictions, banners, and the
  `payment_endpoint` file;
- what payment providers answer;
- files that other programs running as `mobile` can change, such as
  Codling's caches;
- web content shown in depictions.

Codling registers no URL schemes, so other apps cannot send it commands.

## Findings

| # | Finding | Rating | Fix |
| - | ------- | ------ | --- |
| 1 | Purchased packages were installed without apt's signature check | High | Fixed |
| 2 | A purchased package's name and version from a source's index named the downloaded file unchecked | Medium | Fixed |
| 3 | The UDID was sent to every payment provider when a paid package's page opened, signed in or not | Medium (privacy) | Fixed |
| 4 | A source served over HTTP could have its payment provider swapped by anyone on the network | Low | Fixed |
| 5 | Requests to providers followed redirects to HTTP, sending the token again in the clear | Low | Fixed |
| 6 | A timeout stopped the helper in the middle of a change | Low | Fixed |
| 7 | `take-purchase` reached the download through directories a `mobile` program can swap for links | Low | Fixed |

### 1. Purchases skipped the signature check (High)

The helper installed a purchase by giving apt the path of the checked
`.deb`. apt checks signatures only for packages it takes from a source; a
file named on its command line is installed without that check. A paid
package from a source that is not signed was therefore installed without the
"Not verified" confirmation that every other package from such a source
needs. The hash check in `take-purchase` showed that the file was the one
the source lists, but not that the source was signed.

**Fix.** A purchase never reaches apt as a file. `stage_purchases` asks
`apt-get install --print-uris`, against an empty cache, for the name apt
gives the download (`NAME_VERSION_ARCH.deb`, with `:` written `%3a`). It
then copies the checked copy into apt's archive cache under that name, and
apt installs `package=version` from there. apt runs the same check as for any
package: from a source that is not signed, it refuses without
`--trust-unsigned`, which the app passes only after the user confirms. The
app's download step runs that check before anything changes, so the user
sees the confirmation in the review, as with free packages.

**Tests.** `scripts/test-apt-trust.sh` runs a real apt against two local
repositories, one signed with a throwaway key. It checks these behaviors:
a file on the command line is taken without a check; a cached archive from
the unsigned source is refused without consent and taken with it; a cached
archive from the signed source is installed without a download; and the
helper reads apt's real `--print-uris` output. `scripts/test-purchases.sh`
covers the name parsing, which refuses paths, quotes and other packages, and
the copy into the cache.

### 2. Unchecked names for the purchase download (Medium)

A source's index gives the package name and version. Codling named the
download `NAME_VERSION.deb` in its caches before the helper checked either.
A source with a payment provider could list a name like
`../../Library/Preferences/x` and have Codling write the provider's file
there, as `mobile`.

**Fix.** `PurchaseInbox.file` returns a name only for a name and version the
helper accepts (`PackageOperation.purchasedFileName`). Codling refuses to
download anything else. Tested in `AptPlanTests`.

### 3. UDID sent while signed out (Medium, privacy)

Opening a paid package's page asked its provider for the price with a POST
that carried the device's UDID, even when the user had never signed in to
that provider.

**Fix.** Signed out, Codling asks with a GET that carries nothing about the
device, as Zebra does. Signed in, it sends the token and the device as
before, which the provider needs to say whether the user bought the package.
The UDID now leaves the device only for providers the user signed in to,
and on the sign-in page itself. Tested in `PaymentProviderTests`.

### 4. Payment provider named over HTTP (Low)

The `payment_endpoint` file of a source served over HTTP was read over HTTP,
so someone on the network could name their own provider. Tokens are kept per
provider, so no token could leak. But the user would have been offered a
sign-in and a checkout on the other provider's pages.

**Fix.** The file is read over HTTPS only. A source served over HTTP is asked
at the same address over HTTPS. Tested in `PaymentProviderTests`.

### 5. Redirects off HTTPS (Low)

Provider requests used the shared URL session, which follows redirects. A
307 or 308 to an `http://` address would have sent the POST body with the
token again, in the clear.

**Fix.** Provider requests refuse redirects that leave HTTPS
(`HTTPSOnlyRedirects`). The request then ends with the redirect's own
answer, which Codling shows as an error.

### 6. Timeout during a change (Low)

Codling killed the helper with SIGKILL when a command ran past its time
limit: 30 minutes for `apply`, 15 for `configure-pending`. apt kept running,
but it writes its progress to a pipe that the dead helper had held. apt and
dpkg could then stop on SIGPIPE half way through a change.

**Fix.** `apply` and `configure-pending` have no time limit. Commands that
only download or read keep theirs, since stopping them changes nothing.

### 7. Inbox reached through links (Low)

`take-purchase` opened the download with `O_NOFOLLOW`, which applies only to
the last part of the path. A program running as `mobile` could replace one
of the directories on the way with a link. The helper, as root, would then
have read and deleted a file of the same name elsewhere. Reading was already
safe, because the file had to belong to `mobile` and match apt's hash.
Deleting was not.

**Fix.** The helper opens each directory from mobile's home down with
`O_NOFOLLOW | O_DIRECTORY`, and opens and deletes the file relative to the
last one. Tested in `scripts/test-purchases.sh`.

## Checked and found sound

- **The helper.**
  - It takes a fixed list of commands, and names, versions and addresses
    are checked against short character lists.
  - It takes no paths from its caller and finds the jailbreak root from its
    own path.
  - It clears the environment and sets the file mode mask.
  - Its programs run with a fixed `PATH`, stdin from `/dev/null`, and no
    other descriptors.
  - Backups and purchases live in directories only root can write.
  - Removing a backup or source never follows links.
- **Links.**
  - Codling registers no URL schemes.
  - Links in depictions and pages open only `http`, `https`, other
    depictions, packages, and `mailto`, `tel` and `sms`. Anything else does
    nothing.
- **Web depictions.**
  - WebKit draws them in its own sandboxed process, with no script bridge to
    Codling, and in a private session.
  - Pages cannot open windows. Navigation is limited to `http`, `https`,
    `about`, `data` and `blob`.
- **Payments.**
  - Tokens are kept per provider in the Keychain, readable after first
    unlock on this device only.
  - The payment secret needs Face ID, Touch ID or the passcode.
  - Sign-in uses the system's sign-in sheet.
  - Checkout and download addresses must be HTTPS, and a download is checked
    against apt's hash before root keeps it.
- **Signatures.**
  - `apt-get update` reads unsigned sources (`AllowInsecureRepositories`).
    apt still refuses a signed source that stops being signed, since
    `AllowDowngradeToInsecureRepositories` stays off.
  - Installs from unsigned sources need the user's confirmation, now
    purchases included.
  - Codling's own source view checks Release signatures with `gpgv` against
    the keys apt trusts. It checks indexes against the Release checksums.
- **Device details.** Sources and media hosts get the device model and the
  iOS version in the `User-Agent`, `X-Machine` and `X-Firmware` headers, as
  with other package managers. Nothing else about the device is sent, and
  Codling does not track its users.

## After the review: opening .deb files

Added on 2026-11-21, after the findings above were fixed. Codling now
declares the Debian package type (`CFBundleDocumentTypes` in `App/Info.plist`),
so it shows in the share sheet and in Files for a `.deb`, as Sileo and Zebra
do. This gives other apps a new input: a file they hand to Codling. It still
registers no URL schemes.

- **Nothing happens without the user.** Opening a file only shows what its
  control fields say. It is installed after the user taps Install and then
  Confirm in the queue's review, which lists everything apt would change.
- **No paths reach root.** Codling copies the file iOS gives it to
  `Library/Caches/com.nexusjb.codling/files/TOKEN.deb`, where TOKEN is 128
  random bits in hex. `take-file TOKEN` accepts only 32 lowercase hex digits,
  opens the inbox through each directory without following links, as
  `take-purchase` does (finding 7), and takes only a regular file owned by
  `mobile`, at most 1 GB. It unlinks the file as soon as it is open, copies
  it to `/var/lib/codling/files`, which only root can write, and reads the
  control fields from that copy with `dpkg-deb --field`. A file `dpkg-deb`
  cannot read, or that names no valid package and version, is deleted.
- **What the user sees is what is installed.** The `%TOKEN` operation gives
  apt the path of root's copy, the same file `dpkg-deb` read. A program
  running as `mobile` can swap the file in the inbox before the helper opens
  it, but then the user sees that file's name and version, and it could as
  well have changed the file before it was shared.
- **No source vouches for it.** apt does not check signatures for a file named
  on its command line (`scripts/test-apt-trust.sh`, check 1). That is what
  the user chose, so the sheet says plainly that Codling cannot check who made
  the file. Its dependencies still come from the sources, with their usual
  checks.
- **Wrong architecture.** A package for rootful jailbreaks (`iphoneos-arm`) or
  for the other scheme cannot be queued, and the sheet says why.

Tested with `scripts/test-purchases.sh` (tokens, the files inbox, root's copy
and reading control fields) and `scripts/test-apt-trust.sh` (an opened file
installs with its dependency from a source, one whose dependency no source
has is refused, and the helper reads real `dpkg-deb` output), and in
`OpenedPackageTests`.

## Testing

- `scripts/test-apt-trust.sh`: 10 checks, run as root and as a normal user
  with apt 2.8.3.
- `scripts/test-purchases.sh`: 260 checks.
- `scripts/test-sources.sh` and `scripts/test-repack.sh` still pass.
- Core tests (`PaymentProviderTests`, `AptPlanTests`) run in CI.
- On a device, with build 0.1.0~dev.116 on an iPhone 14 Pro Max (iPhone15,3),
  iOS 16.3.1, Dopamine rootless, these all passed:
  1. A package bought on Nexus was removed, then installed again from
     Codling: it downloaded, and apt installed it from its cache.
  2. A free package from a signed source installed with Confirm.
  3. A package from an unsigned source asked for Install Without
     Verification, and installed after it.
  4. Signed out of Nexus, a paid package's page still showed its price.
  5. Signed in again, bought packages showed as bought.
  6. Upgrade All finished.
