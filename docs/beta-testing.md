# Testing Codling in the closed beta

Thank you for testing Codling. The closed beta is for finding what breaks on
devices and jailbreaks we do not have, before anyone else installs Codling.
Each run of the checks below, on your device, tells us more than any number
of runs on ours.

## Who can test

| You need | |
| --- | --- |
| A device | iPhone XS, iPhone XR or later, or an iPad with an A12 chip or newer |
| iOS | 15 or later |
| A jailbreak | Dopamine, rootless or RootHide |

Rootful jailbreaks are not supported. Burrow, the tweak loader that Safe Mode
needs, runs on rootless jailbreaks for now; on RootHide, Codling works
without it.

## Installing

Ultra Team sends each tester the address of the beta source with the
invitation. Add it in Sileo or Zebra and install Codling from it: the source
gives your device the build for its jailbreak.

Keep Sileo or Zebra installed. Codling works beside them and removes neither,
so if something goes wrong, you still have a package manager you know.

To stop testing, remove Codling in Sileo or Zebra. Nothing else changes.

## The checks

Do them in order. A check you cannot do, such as one about paid packages
when you have not bought any, is left out. Note the result of each.

1. **Launch.** Open Codling. It opens on Featured.
2. **Device.** Open Device Info at the bottom of Featured. Your device, iOS
   version and jailbreak are right. Leave the UDID hidden.
3. **Refresh.** In Sources, tap the refresh button. Every source refreshes,
   or says plainly why it could not.
4. **Add a source.** Add a source with +, then remove it by swiping it.
5. **Security Check.** Open a signed source, such as Procursus or your
   jailbreak's own, and scroll to Security Check. It says the source is
   signed.
6. **Search.** Search for a package you know.
7. **Package page.** Open a package with a depiction. It shows inside
   Codling.
8. **Install.** Tap GET on a small free package, then Confirm on the queue
   bar and in the review. It says the changes were applied.
9. **Remove.** Tap REMOVE on that package and confirm. It is removed.
10. **Undo.** In the Queue tab, tap Undo Last Change and confirm. The package
    you removed comes back.
11. **Respring.** After a change has been applied, tap Restart SpringBoard
    under the result. SpringBoard restarts at once.
12. **Updates.** If updates are waiting, the Installed tab and Codling's icon
    show how many. Upgrade All installs them.
13. **Paid packages.** If you bought packages from a source with a payment
    provider, such as Havoc, Chariz or Nexus: sign in from the account
    button in Sources, then install one you own.
14. **Relaunch.** Close Codling from the app switcher and open it again. It
    opens at once.

On RootHide, checks 5, 9, 10 and 13 matter most: they cover what differs
there.

## Reporting

Open a [beta test report](https://github.com/Nexus-jb/codling/issues/new?template=beta-report.yml)
on GitHub, or post the same in the testers' channel. Include:

- your device, iOS version and jailbreak;
- the Codling version, from Device Info;
- which checks passed, and for each one that did not, what you did and what
  you saw, with a screenshot.

When Codling closes by itself, it leaves a crash report. Find it in Settings,
Privacy & Security, Analytics & Improvements, Analytics Data, in the entries
that start with `Codling`, and attach it.

Never post your UDID, passwords, sign-in codes or payment details. A
security problem goes to us privately, as [SECURITY.md](../SECURITY.md)
explains, not into a report.

## What this beta does not have yet

- Codling does not send crash reports anywhere. Share them yourself, as
  above.
- Burrow, and so Safe Mode, on RootHide.
