# 🌙 Baby Monitor

A private, self-hosted baby monitor. Put an old phone, tablet or laptop in the
nursery as the **baby station**. Then open the app on your iPhones as
**parent stations** to get:

- 📹 Live video and sound, sent **directly** between devices over WebRTC
  (no cloud service sees or stores anything)
- 🔔 **Lock-screen notifications** when the baby makes noise, even when your
  iPhone is locked
- ⚠️ A **lost contact alarm** if the baby station stops reporting (battery died,
  Wi-Fi dropped, app closed), so silence never just means "no news"
- 🔊 Each parent sets their own sound level and duration for alerts
- 👀 Any number of parents at once, with automatic reconnect
- 🌙 A dark screen mode for the nursery device, with the screen kept awake so it
  keeps streaming

## How it works

```
 Baby station ──── video + audio (WebRTC, peer-to-peer) ───▶ Parent iPhones
      │                                                          ▲
      └── sound level ──▶  server.js ──── push notifications ────┘
                           (any always-on computer at home)
```

`server.js` is a small Node server on a computer at home, such as a laptop, Mac
mini, Raspberry Pi or NAS. It serves the app and helps the devices find each
other. It also watches the baby station's sound level four times a second.
When the sound stays above your chosen level, or the baby station goes quiet,
it sends a **push notification**. This is what makes alerts work on iPhone: iOS
pauses web pages when the phone locks, but push notifications still arrive.
Video and audio never pass through the server.

## Setup for iPhone (recommended: Tailscale)

iPhones only allow push notifications for web apps that are **added to the Home
Screen** and served over **https with a real certificate**. The easiest way to
get both is [Tailscale](https://tailscale.com). It's free for personal use and
gives the server a private address with a valid certificate. As a bonus, the
monitor also works when you're away from home, and nothing is exposed to the
internet.

### 1. Server (once)

On the always-on computer, install [Node.js](https://nodejs.org) 18+ and
[Tailscale](https://tailscale.com/download). Sign in to Tailscale.

In the [Tailscale admin console](https://login.tailscale.com/admin/dns), turn on
**MagicDNS** and **HTTPS Certificates**.

Then, in this folder:

```bash
npm install
MONITOR_PASSWORD="pick-something-long" USE_HTTP=1 HOST=127.0.0.1 PORT=8080 npm start
```

In another terminal:

```bash
tailscale serve --bg 8080
```

That prints your address, something like `https://homeserver.tail1234.ts.net`.

### 2. Both your iPhones

1. Install the **Tailscale** app and sign in. Your wife can either use the same
   account or be invited to your tailnet (admin console → Users → Invite).
2. In **Safari**, open the `https://….ts.net` address.
3. Tap **Share** → **Add to Home Screen**, then open **Baby Monitor** from the
   Home Screen. Push notifications only work from the Home Screen app.
4. Enter the password, choose **Parent station**, and tap Start.
5. Under **🔔 Lock-screen alerts**, tap **Turn on** and allow notifications.
   Then tap **Send test** and lock your phone to check that it arrives.
6. **Let the alerts through at night:** Settings → Focus → **Sleep** (and any
   other Focus you use) → Apps → add **Baby Monitor**. Otherwise Sleep mode will
   silence the alerts.

### 3. Baby station (in the nursery)

On an old iPhone, iPad, Android phone or laptop: install Tailscale, open the
address, choose **Baby station**, and allow camera and microphone. Then:

- Keep it **plugged in**.
- On an iPhone or iPad: set **Settings → Display & Brightness → Auto-Lock →
  Never**. Turn on **Guided Access** (Settings → Accessibility) so the app
  stays in front.
- Point it at the crib and tap **🌙 Dark screen**.

### Tuning alerts

Watch the sound meter while your son sleeps normally. Drag the **Alert when
sound is above** slider (the white line on the meter) a bit above that level.
**For at least** stops short noises, like a cough or a car outside, from
triggering an alert. Lock-screen alerts use the same settings, with at most one
noise notification per minute.

## Good to know on iPhone

- **When your phone is locked, rely on notifications.** iOS may stop the live
  sound from a web app when the screen locks or you switch apps. Noise and
  lost-contact alerts still arrive as notifications. For live sound all night,
  leave the app open on screen on the nightstand. The screen is kept on, so
  turn the brightness down.
- **Silent mode:** notifications follow your ringer setting. With the ring /
  silent switch on silent, the phone only vibrates. In-app alert beeps do play
  in silent mode while the app is open.
- The volume slider is hidden on iPhone because iOS ignores it. Use the phone's
  volume buttons.
- Requires **iOS 16.4 or newer**.
- If the **server** computer goes down, nobody is left to send notifications.
  Keep it on and plugged in.

**This app helps you keep an eye on your son. It is not a medical device.** It
does not check breathing or movement, and Wi-Fi, phones and servers can fail.

## Without Tailscale (home Wi-Fi only, no push)

```bash
npm install
MONITOR_PASSWORD="pick-something-long" npm start
```

This serves `https://<computer-ip>:8443` with a self-signed certificate. Accept
the browser warning once per device. Live video, sound and in-app alerts work.
**Lock-screen notifications won't**, because browsers don't allow them with a
self-signed certificate. Any other HTTPS reverse proxy with a real certificate
(Caddy, nginx, Cloudflare Tunnel) works like the Tailscale setup.

## Configuration

Set these as environment variables:

| Variable           | Default                     | Purpose |
|--------------------|-----------------------------|---------|
| `MONITOR_PASSWORD` | *(required)*                | Family password everyone enters |
| `PORT`             | `8443`                      | Port to listen on |
| `HOST`             | all interfaces              | e.g. `127.0.0.1` to only accept connections from a local proxy |
| `USE_HTTP`         | off                         | `1` = plain HTTP, for use behind an HTTPS proxy |
| `TLS_CERT`, `TLS_KEY` | self-signed in `certs/`  | Paths to your own certificate and key |
| `DATA_DIR`         | `./data`                    | Where push keys and subscriptions are stored |
| `VAPID_SUBJECT`    | this repo's URL             | Contact URL or `mailto:` sent to push services |
| `ICE_SERVERS`      | Google STUN                 | JSON list of WebRTC ICE servers, e.g. a TURN relay |

Run the tests with `npm test`.
