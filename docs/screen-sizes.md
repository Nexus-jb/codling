# Screen sizes

Codling runs on every iPhone and iPad it can be installed on: an A12 chip or
newer (the package refuses older ones), from the 4.7-inch iPhone SE to the
13-inch iPad Pro, upright and on its side, and on an iPad in Split View,
Slide Over and Stage Manager windows.

## How the layout adapts

Codling lays pages out by the size of its window, never the screen's: on an
iPad the window can be a third of the screen.

- **A column in the middle.** Every page keeps its cards and rows in a
  column at most 760 points wide, padding included, and a package's page at
  most 592 (`PageLayout` in `App/AppChrome.swift`). On an iPhone held upright
  the column is the window. On an iPad, or an iPhone on its side, the column
  stays in the middle instead of stretching across the window.
- **Sources in two columns.** In a regular-width window, as on an iPad or
  an iPhone Pro Max on its side, Sources shows the list of sources beside
  the page of the source chosen, All Packages to begin with, as Sileo does
  on an iPad. Both columns stay on screen, upright too.
- **Titles.** Over a centered column, in a regular-width window, Installed
  shows its title in the middle of the navigation bar instead of as a large
  title at the left edge. On an iPad with iOS 26 it keeps the large title,
  since the tab bar takes the middle of the bar there.
- **Sizes from the column.** Featured's banners, a source's banners and a
  depiction's screenshots are sized from the column's measured width.
  Featured shows two banners across on an iPhone and more where each can be
  250 points wide.
- **The tab bar.** Before iOS 26, Codling draws its own floating tab bar. It
  is at most 520 points wide, with the queue bar above it the same, and 50
  points high instead of 64 when the window is short, as on an iPhone on its
  side. On iOS 26 the system's tab bar takes its place: at the bottom on an
  iPhone, at the top on an iPad.

## Checking the layout

Nobody on the team has every device, so the [Layout screenshots
workflow](../.github/workflows/screenshots.yml) takes screenshots of the main
pages on simulators: Featured, Sources, All Packages, a package, Installed and
Search, upright and on their side. It publishes them as the
`layout-screenshots` prerelease, which each run replaces.

The simulators run the app on real sources from the internet:
`ScreenshotTests/root` is laid out like a rootless jailbreak's root, with
four sources in `etc/apt` and a short dpkg status file, and simulator
builds read the jailbreak root from `CODLING_SIMULATOR_ROOT`. Builds for
devices do not have this. To take them on a Mac with Xcode 26, XcodeGen and
gpgv:

```sh
xcodegen generate
scripts/layout-screenshots.sh build products
scripts/layout-screenshots.sh shoot products 18 "iPad Pro 13-inch (M4)" screenshots
```

The workflow's simulators: iPhone SE (3rd generation), iPhone 12 mini,
iPhone 11 Pro Max (the size of the iPhone XS Max), iPhone 16 Pro Max, iPad
mini (6th generation), iPad (10th generation) and iPad Pro 13-inch (M4) on
iOS 18, which draw Codling's own tab bar, and iPhone 17 Pro Max and iPad Pro
13-inch (M5) on iOS 26.

| Date | What was checked | Result |
| --- | --- | --- |
| 2026-11-21 | All nine simulators, before the changes above | On iPads every page stretched across the window and the tab bar ran from edge to edge; on an iPhone on its side the tab bar took a third of the height |
| 2026-11-21 | All nine simulators, after them | Pages in a centered column on iPads, the tab bar at most 520 points wide and 50 high on an iPhone on its side; iPhones held upright unchanged |
