# 🌙 Baby Monitor

A private, self-hosted baby monitor. Put an old phone, tablet or laptop in the
nursery as the **baby station**. Then open the same page on your phones as
**parent stations** to get:

- 📹 Live video and sound, sent **directly** between devices over WebRTC
  (no cloud service sees or stores anything)
- 🔊 **Noise alerts** with a sound, vibration and notification when crying stays
  above a level you choose for a few seconds. Each parent can set their own level.
- ⚠️ A **lost contact alarm** if the baby station stops reporting (battery died,
  Wi-Fi dropped, app closed), so silence never just means "no news"
- 👀 Any number of parents watching at once, with automatic reconnect
- 🌙 A dark screen mode for the nursery device, with the screen kept awake so it
  keeps streaming
- 🔒 One shared family password

## Getting started

You need [Node.js](https://nodejs.org) 18 or newer on any always-on computer
on your home network, such as a laptop, Raspberry Pi or NAS.

```bash
npm install
MONITOR_PASSWORD="pick-something-long" npm start
```

The server prints addresses like `https://192.168.1.20:8443`.

1. **In the nursery:** open that address on the old phone or tablet. Enter the
   password, pick **Baby station** and tap Start. Allow camera and microphone
   access. Plug it in, point it at the crib, and tap **🌙 Dark screen**.
2. **On your phones:** open the same address, pick **Parent station**, and allow
   notifications. Use "Add to Home Screen" to get an app icon.

The first time on each device the browser warns about the certificate. This is
expected: the server makes its own (self-signed) certificate, because browsers
only allow the camera and microphone on `https://` pages. Choose "Advanced →
Proceed" once per device. On iPhone you may need to tap "Show Details → visit
this website".

### Tuning alerts

Watch the sound meter on a parent station while the baby sleeps normally. Drag
the **Alert when sound is above** slider (the white line on the meter) a bit
above that level. **For at least** stops short noises, like a cough or a car
outside, from triggering an alert. After an alert there is a 30-second pause
before the next one.

## Good to know

- **Keep the parent app open.** Phones pause web pages in the background. On
  Android, sound usually keeps playing with the screen off. iOS is stricter:
  keep the page open on screen, for example dimmed on the nightstand. The
  lost contact alarm tells you if the connection drops.
- **Keep the baby station plugged in.** Streaming video uses a lot of power.
- **This app helps you keep an eye on your son. It is not a medical device.** It
  does not check breathing or movement, and Wi-Fi and phones can fail.
- The audio is sent without noise suppression on purpose, so quiet sounds such
  as whimpering still come through.

## Watching from outside the home

Out of the box this works on your home Wi-Fi. To use it away from home:

- The easiest option is [Tailscale](https://tailscale.com), installed on the
  server and both phones. Then open the server's Tailscale address. Nothing is
  exposed to the internet.
- Or run the server behind a reverse proxy or tunnel with a real certificate.
  Start it with `USE_HTTP=1` and let the proxy handle HTTPS. On mobile networks
  you may also need a TURN relay (see below).

## Configuration

Set these as environment variables:

| Variable           | Default                     | Purpose |
|--------------------|-----------------------------|---------|
| `MONITOR_PASSWORD` | *(required)*                | Family password everyone enters |
| `PORT`             | `8443`                      | Port to listen on |
| `USE_HTTP`         | off                         | `1` = plain HTTP, for use behind an HTTPS reverse proxy |
| `TLS_CERT`, `TLS_KEY` | self-signed in `certs/`  | Paths to your own certificate and key |
| `ICE_SERVERS`      | Google STUN                 | JSON list of WebRTC ICE servers, e.g. `[{"urls":"turn:turn.example.com","username":"u","credential":"p"}]` |

## How it works

```
 Baby station ──── video + audio (WebRTC, peer-to-peer) ───▶ Parent stations
      │                                                          ▲
      └── sound level ──▶  server.js (signaling + web app) ──────┘
```

`server.js` is a small Node server. It serves the web app in `public/`, checks
the password, and passes WebRTC connection setup messages between the baby
station and the parents. It also relays the baby station's sound level four
times a second. Parents use this level for noise alerts and to notice when the
baby station goes quiet. Video and audio never pass through the server.

Run the tests with `npm test`.
