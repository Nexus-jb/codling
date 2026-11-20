# Sources known for piracy

Codling warns before it adds a source that published articles describe as
handing out paid tweaks or apps without their developers' permission, and
marks such a source on the Sources tab and on its page. It never blocks,
hides or slows a source: the person decides, with the warning in front of
them. The list lives in
[`Core/Sources/CodlingCore/PiracySources.swift`](../Core/Sources/CodlingCore/PiracySources.swift),
and Codling checks it on the device: no address is sent anywhere to be
checked.

## What gets on the list

A source is listed when at least one published article, not a forum post,
says that it distributes other developers' paid packages or apps for free,
or cracked apps. An entry names a host, which covers its subdomains, and
sometimes a path on that host.

Several of these sources are old, and some no longer answer. An entry stays
until there is evidence that the source no longer hands out other people's
paid work.

| Source | Address | Evidence |
| ------ | ------- | -------- |
| AppCake (iPhoneCake) | `cydia.iphonecake.com` | [Gadget Hacks: How to get cracked apps for your jailbroken iPhone](https://smartphones.gadgethacks.com/how-to/get-cracked-apps-for-your-jailbroken-iphone-ipod-touch-0121964) |
| Hackulous | `cydia.hackulo.us` | [Gadget Hacks: sources that "contain cracked apps"; Hackulous hosted Installous, which downloads cracked IPAs](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| cydia.vn | `cydia.vn` | [Hackmag: paid tweaks from other sources, free to download](https://hackmag.com/mobile/jailbreaking-for-dummies) |
| xSellize | `cydia.xsellize.com` | [International Business Times India: sources for cracked paid apps, themes and tweaks](https://amp.ibtimes.co.in/top-5-paid-cydia-tweaks-how-get-cracked-legal-apps-games-themes-free-657748); [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| iHackStore | `ihackstore.com/repo` | [International Business Times India](https://amp.ibtimes.co.in/top-5-paid-cydia-tweaks-how-get-cracked-legal-apps-games-themes-free-657748); [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| iHacks | `ihacksrepo.com` | [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| P0dulo | `p0dulo.com` | [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| BiteYourApple | `repo.biteyourapple.net` | [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |
| HackYouriPhone | `repo.hackyouriphone.org` | [International Business Times India](https://amp.ibtimes.co.in/top-5-paid-cydia-tweaks-how-get-cracked-legal-apps-games-themes-free-657748); [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961); [TechJunkie: a copy of IAP Cracker](https://techjunkie.com/?p=33569) |
| iNSANELYi | `repo.insanelyi.com` | [Hackmag: "lots of cracked tweaks"](https://hackmag.com/mobile/jailbreaking-for-dummies); [International Business Times India](https://amp.ibtimes.co.in/top-5-paid-cydia-tweaks-how-get-cracked-legal-apps-games-themes-free-657748) |
| Sinful iPhone | `sinfuliphonerepo.com` | [International Business Times India](https://amp.ibtimes.co.in/top-5-paid-cydia-tweaks-how-get-cracked-legal-apps-games-themes-free-657748); [Gadget Hacks](https://smartphones.gadgethacks.com/how-to/add-useful-sources-your-jailbroken-idevice-0140961) |

## Proposing or contesting an entry

Open an issue or a pull request on
[Nexus-jb/codling](https://github.com/Nexus-jb/codling) with a link to a
published article, or, to contest an entry, with what has changed. A pull
request that adds an entry adds its row here too. Entries are reviewed on
their evidence alone, whoever runs the source.

## What the warning says

> *Known for Piracy.* NAME is known for handing out paid tweaks and apps
> without their developers' permission. Cracked packages are often outdated
> or unstable and can carry malware, and they take income from the people who
> make tweaks. Codling does not block any source. Add this one only if you
> trust it.

The buttons are "Don't Add", the default, and "Add Anyway".
