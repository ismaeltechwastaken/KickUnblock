# KickUnblock Privacy Policy

## Playback

Live playback uses the Amazon IVS player, the same player Kick uses. It sends playback quality data to Amazon. VODs and clips use Apple's player.

KickUnblock does not add Mux, Datazoom, Datadog, Firebase, advertising SDKs, attribution SDKs or ad-identifier APIs.

## Data stored on your device

| Data | Storage | Removal |
| --- | --- | --- |
| Local followed channels and saved clips/VODs/channels | UserDefaults | Remove the item, Clear all local data or delete the app |
| Tweaks and advanced settings | UserDefaults | Reset all tweaks or Clear all local data |
| Blocked chat words and users | UserDefaults | Remove them in Tweaks, Clear all local data or delete the app |
| OAuth credentials | iOS Keychain, ThisDeviceOnly | Sign out or Clear all local data |
| Emote/image data | Bounded memory caches and system URL cache | Clear all local data or system eviction |
| Optional Kick web sign-in | WebKit website data store | Sign out of web session or Clear all local data |
| Downloaded VODs/clips | Documents/Downloads, visible in Files | Delete download or app |
| Opt-in playback event buffer | Memory only | Disable diagnostics or restart app |

Kick web sign-in happens on Kick's own page. OAuth and web sign-in are separate options. The app checks who you are signed in as with Kick before showing account features. Watching here is not known to count toward Drops.

## Network connections

The app connects to Kick's website/public APIs and media/image CDNs for the requested content. It connects to Kick identity services for optional OAuth. It also connects to Pusher for chat and enabled emote providers (7TV and optional BTTV/FFZ). When a live chat is open with 7TV emotes or 7TV badges and name colors on (both are on by default and can be turned off in Tweaks), the app also keeps a connection to 7TV's live update service (events.7tv.io). It tells the service the channel's Kick ID so emote changes and other viewers' 7TV badges and name colors arrive as they happen. It sends no account or identity of yours. Kick's login page and web player are Kick's own pages.

Copying or opening a stream link shares a link that expires. These links never go into diagnostic exports. KickUnblock has no servers of its own, so your sign-in and cookies only go to Kick.

## Privacy questions and reports

For general privacy questions, open an issue on this repository without personal data. For anything sensitive, use the private reporting route in [SECURITY.md](SECURITY.md). [SUPPORT.md](SUPPORT.md) explains what to redact. Never share tokens, cookies, client secrets, signed playback URLs or signing material.
