# Refresh speed of Codling 0.1 and Sileo (step 36)

Step 36 of the work plan: how long it takes to refresh the same sources in
Codling and in Sileo, on the same device and network. Codling took 2.2
seconds on average and Sileo 4.0, so Codling was about 1.8 times as fast.

- **Date:** 2026-11-21
- **Codling:** 0.1.0~dev.116
- **Sileo:** the copy installed on the device (version not recorded)
- **Device:** iPhone 14 Pro Max (iPhone15,3, A16), iOS 16.3.1, Dopamine
  rootless
- **Network:** mobile data (5G), no Wi-Fi
- **Sources:** the same 14 in both apps, listed below

## Results

Each app refreshed three times. Both recordings were made within a minute
of each other.

| Run | Sileo | Codling |
| --- | --- | --- |
| 1 | 4.0 s | 2.6 s |
| 2 | 3.9 s | 1.8 s |
| 3 | 4.0 s | 2.1 s |
| Average | 4.0 s | 2.2 s |

An earlier round, also on mobile data, gave Sileo 3.6, 4.0 and 3.8 seconds,
and Codling 2.7, 4.5 and 2.5. The signal dropped during Codling's second
run. In that run the seven sources on screen were done in 2.1 seconds, and
one further down the list took the rest. Mobile data varies too much to
average across rounds, so that round is not counted. It does not change the
result.

## How it was measured

- Both apps were recorded on screen at 60 frames per second. The recordings
  were then read at 10 frames per second, so each time is good to about 0.1
  seconds.
- A refresh starts at the first frame where the app shows it is refreshing.
  In Codling, that is when the spinner replaces the refresh button. In
  Sileo, it is when the pull-to-refresh spinner is fully drawn.
- A refresh ends at the first frame where that spinner is gone.
- Each refresh is the ordinary one a user does: nothing changed in the
  sources between runs. Codling asks each source only for files that
  changed since its last refresh.
- Sileo writes apt's lists as it refreshes. Codling shows the refreshed
  sources first, then has apt read them in the background (`apt-get
  update`). That update is not in Codling's times. An install waits for it
  if it is still running.

## Sources

BigBoss (`http://apt.thebigboss.org/repofiles/cydia/`), Cercube, Chariz,
Deno Repo, ElleKit, Havoc, ichitaso, Limneos, MiRO's Repo, Nexus
(`https://repo.nexusjb.com/`), Nexus Beta, PoomSmart's Repo, Procursus and
TIGI Software. All are served over HTTPS except BigBoss.
