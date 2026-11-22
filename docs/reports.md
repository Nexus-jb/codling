# Crash reports and install results for repositories

Codling can send two kinds of reports to the repository a package came
from, so that the package's developer learns what breaks on devices they do
not have:

- a **crash report**, when a process crashed and Burrow's crash log blames
  one of the package's tweaks;
- an **install result**, saying whether installing or upgrading the package
  worked.

Both leave the device only with the user's consent. Codling sends a crash
report after the user has seen it on the Burrow screen and tapped **Send**,
or, if they turned on **Always Send** for that repository, the next time
Codling opens after Burrow records a new crash of one of its tweaks. It sends
install results only while the user has **Share Install Results** on, in
System. Both are off until the user acts.

Any repository can receive reports, and Codling treats every one the same:
a report goes only to the repository that offers the package, never to
Codling's developers or to Nexus unless Nexus is that repository.

Separately, the user can share any crash report themselves: Share on the
Burrow screen opens the system's share sheet with the report as a text
file, a few lines to read followed by the same JSON, to send wherever they
choose.

## Receiving reports

Serve a `reports_endpoint` file in the same places as `payment_endpoint`:
next to `Release`, at the repository's address. It holds one HTTPS address
on its first line, for example:

```
https://api.example.com/codling/
```

Codling reads the file over HTTPS only, follows redirects only to HTTPS
addresses, and ignores a file larger than 4 KB or an address that is not
HTTPS or has a query. It then sends:

| Request | Body |
| --- | --- |
| `POST <address>crash` | a crash report |
| `POST <address>install` | an install result |

Both are JSON (`Content-Type: application/json`), with a `User-Agent` of
`Codling/<version>`. Answer with any 2xx status to accept a report. Codling
tells the user when a crash report was not accepted, and keeps it so that
they can send it again; it does not send an install result twice.

## A crash report

```json
{
  "format": 1,
  "id": "6d2f0c4b9a7e1f3d5c8b2a6e4f0d9c7b5a3e1f2d4c6b8a0e9f7d5c3b1a2e4f6d",
  "date": "2026-11-22T08:12:00Z",
  "package": "com.example.tweak",
  "version": "1.2.3",
  "architecture": "iphoneos-arm64",
  "tweak": "ExampleTweak",
  "process": "com.apple.springboard",
  "reason": "EXC_BAD_ACCESS (SIGSEGV) in ExampleTweak.dylib (-[ExampleView layoutSubviews] + 16)",
  "exception": {
    "type": "EXC_BAD_ACCESS",
    "signal": "SIGSEGV",
    "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000010",
    "name": null,
    "message": null
  },
  "frames": [
    { "image": "ExampleTweak.dylib", "offset": 16400, "symbol": "-[ExampleView layoutSubviews]", "symbolOffset": 16 },
    { "image": "UIKitCore", "offset": 1234567, "symbol": null, "symbolOffset": 0 }
  ],
  "otherTweaks": [
    { "tweak": "Other", "package": "com.example.other", "version": "2.0" }
  ],
  "device": "iPhone15,3",
  "system": "16.3.1",
  "build": "20D67",
  "jailbreak": "rootless",
  "loader": "burrow",
  "client": "Codling 0.1.0"
}
```

| Field | What it is |
| --- | --- |
| `format` | 1. A later format may add fields; read the ones you know. |
| `id` | SHA-256, in hex, of the crash report's incident identifier. The same crash sent twice has the same `id`; the incident identifier itself is not sent. |
| `date` | When the process crashed, in UTC. |
| `package`, `version`, `architecture` | The package that installed the tweak to blame, as dpkg lists it. |
| `tweak` | The tweak to blame: the name of its library, without `.dylib`. |
| `process` | The crashed process's bundle identifier, or its executable's name when it has none. |
| `reason` | Burrow's one line about the crash. |
| `exception` | The exception type, signal and subtype from the crash report, and for an uncaught Objective-C exception its name and message (at most 300 characters). Missing parts are `null`. |
| `frames` | The crashed thread, or for an uncaught exception the backtrace it was thrown from: at most 40 frames, each with the image's file name (never its path), the offset in the image, and the symbol and the offset from it when the report has one. |
| `otherTweaks` | The other tweaks loaded in the process when it crashed, with the packages that installed them, since tweaks often crash each other. |
| `device` | The model identifier, such as `iPhone15,3`. |
| `system`, `build` | The iOS version and build. |
| `jailbreak` | `rootless` or `roothide`. |
| `loader` | The tweak loader in use: `burrow` or `ellekit`, or `null` when Codling has not read it. |
| `client` | Codling's version. |

## An install result

```json
{
  "format": 1,
  "package": "com.example.tweak",
  "version": "1.2.3",
  "architecture": "iphoneos-arm64",
  "action": "install",
  "result": "failed",
  "problems": ["unmet-dependencies"],
  "device": "iPhone15,3",
  "system": "16.3.1",
  "build": "20D67",
  "jailbreak": "rootless",
  "loader": "burrow",
  "client": "Codling 0.1.0"
}
```

| Field | What it is |
| --- | --- |
| `action` | `install` or `upgrade`. |
| `result` | `installed` or `failed`. |
| `problems` | When it failed, the names of the problems Codling found in apt's output, such as `unmet-dependencies`, `file-conflict` or `dpkg-failed`. apt's output itself is never sent. An empty list means Codling did not recognise the problem. |

Codling sends one install result for each package a change installed or
upgraded from a repository that has a `reports_endpoint`, once the change
has finished.

## What is never sent

The UDID or any other identifier of the device or the user, the account a
user signed in with, the crash report file, the names of apps other than
the crashed process, file paths, the rest of the installed packages, and
apt's output. A repository sees the request's IP address like any other
request; it should not keep it with the reports.

## Which repository receives a report

The repositories in Codling's index that offer that version of the package
and serve a `reports_endpoint`. When several do, each receives it, and the
user sees them all before sending a crash report.

## What a repository should do with reports

Show them only to the package's developer, group them by package, version,
iOS version and jailbreak, and keep them only as long as the developer
needs them. Counts across all users, such as how often a version installs
and how often it crashes on each iOS version, can be public. Codling cannot
check what a repository does with a report: the user decides whether they
trust it, which is why they see each crash report before it is sent.
