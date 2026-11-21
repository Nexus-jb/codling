# Device test of Codling 0.1 (step 29)

Step 29 of the work plan: everything Codling does, tested end to end on a
real device, from the build that `main` produces.

- **Date:** 2026-11-21
- **Build:** 0.1.0~dev.112, built from `main` after #18 (SHA-256
  `345dec13cb3ce22e552a6db5463f21904e79b298806640e6ec3a563e2a853845`)
- **Device:** iPhone 14 Pro Max (iPhone15,3, A16), iOS 16.3.1
- **Jailbreak:** Dopamine, rootless, with Procursus and apt 2.9.4; Burrow
  0.0.0~dev.100 as the tweak loader
- **Result:** all 21 checks passed

The plan named two devices. The second was an iPhone X (A11), which
Codling no longer supports: Codling and Burrow need A12 or later. RootHide
and iOS 15, 17, 18 and 26 are covered by the tests in CI, not by this run.

## Checks

| # | Area | What was done | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | Install | `dpkg -i` the build | Installs and registers the app | Pass |
| 2 | Launch | Open Codling | Opens on Featured at once, without the launch screen | Pass |
| 3 | Featured | Look through the tab | Banners, Browse Categories, New & Updated (six, See All), Device Info | Pass |
| 4 | Sources | Open the tab | All Packages with its count, then Repositories | Pass |
| 5 | Sources | Add a new source with +, then remove it by swiping | Added and refreshed; removed | Pass |
| 6 | Sources | Hold a source | Share, Copy, Refresh and Remove | Pass |
| 7 | Sources | Open a source | Sections and Security Check | Pass |
| 8 | Search | Search for a package | Results, with the installed mark | Pass |
| 9 | Depictions | Open AutoAnswer's Full Description | The HTML depiction shows inside Codling | Pass |
| 10 | Install | GET a small free package, Confirm on the queue bar, Confirm | "The changes were applied" | Pass |
| 11 | Undo | Undo Last Change in the Queue tab | The package is removed again | Pass |
| 12 | Remove | REMOVE an installed package, Confirm | Removed | Pass |
| 13 | Signatures | GET CameraModes (an unsigned source), Confirm | Not verified, then Install Without Verification installs it | Pass |
| 14 | Respring | Restart SpringBoard | Restarts at once, without a confirmation | Pass |
| 15 | Burrow | System, Burrow: turn a tweak off in one app, then on | The loader and tweaks show; the change applies | Pass |
| 16 | Accounts | Sign out of Nexus, then sign in | Both work | Pass |
| 17 | Buying | Open a paid package not bought, tap its price, Cancel | The price shows; the confirmation appears; nothing is bought | Pass |
| 18 | Bought | GET Ultra Live Widgets, bought on Nexus, Confirm | Downloaded, checked against apt's hash, installed | Pass |
| 19 | Updates | With an update waiting: the badges, then Upgrade All | Number on the Installed tab and the icon; gone after the upgrade | Pass |
| 20 | Relaunch | Close Codling from the app switcher and open it | Opens at once | Pass |
| 21 | Stability | `ls -t /var/mobile/Library/Logs/CrashReporter` | No report for Codling; the one JetsamEvent does not name it | Pass |

Step 28's checks (the largest accessibility text size, the Large Content
Viewer on the tab bar, VoiceOver, Reduce Motion, light and dark) passed on
the same device with 0.1.0~dev.109, the same code as this build.
