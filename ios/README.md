# 🌙 Baby Monitor for iPhone

A native iPhone app. One phone stays in the nursery as the **baby station**;
the other is the **parent station**. At home they connect **directly over your
Wi-Fi**. Away from home they connect **over cellular** through the free
Tailscale app. There is no server and nothing to pay for.

- 🔊 Live sound that **keeps playing when your phone is locked**
- 📹 Live video (about 8 frames per second, which is plenty for a crib) while
  the app is open
- 🔔 **Notifications and an alert tone when the baby makes noise**, using your
  own sound level and duration
- ⚠️ **A lost contact alarm** that repeats every minute if the baby station
  stops responding (battery, Wi-Fi, app closed)
- 📶 **Works over cellular** with Tailscale, with an automatic data saver
  (about 35 MB per hour of listening)
- 🔒 Encrypted with your family password. Phones without it can't connect or
  listen.
- Any number of parents at once

## What you need

- A **Mac** with **Xcode 16** or newer (free from the Mac App Store)
- Your **iPhones** on **iOS 17** or newer, plus a phone or iPad for the nursery.
  An old iPhone works well.
- An **Apple ID**. See [Free or paid Apple account?](#free-or-paid-apple-account)

## Install (on your Mac)

**Once:**
1. Get this project onto your Mac (`git clone`, or download the ZIP from GitHub).
2. Open `ios/BabyMonitor.xcodeproj` in Xcode. Go to Xcode → Settings → Accounts
   and add your Apple ID.
3. Click the **BabyMonitor** project → target **BabyMonitor** → **Signing &
   Capabilities** → **Team**: pick your name. If Xcode says the bundle
   identifier is taken, change it to something unique, e.g.
   `com.yourname.BabyMonitor`.
   Pick your **paid developer team**, not "Personal Team". The project already
   turns on **Time Sensitive Notifications**, so alerts can break through Sleep
   and other Focus modes. (A free "Personal Team" can't use that capability. To
   use one, delete `CODE_SIGN_ENTITLEMENTS` from the build settings.)
4. Connect each iPhone to the Mac with a cable once, unlock it and tap **Trust
   This Computer**.

**Install or renew** with both phones nearby (with a cable, or on the same
Wi-Fi as the Mac once paired):

```bash
cd ios
./install.sh
```

The script builds the app and installs it on every paired iPhone. The first
time on each phone:
- Settings → Privacy & Security → **Developer Mode** → On (the phone restarts).
- Settings → General → VPN & Device Management → your Apple ID → **Trust**.

With a paid developer account the app keeps working for **a year**. Run
`./install.sh` again to renew it or to get updates; your settings are kept.
(With a free Apple ID it would stop after 7 days.)

## Use

**Nursery phone:** open Baby Monitor → **Baby station**, enter a family
password, then **Start**. Allow camera, microphone and local network access.
Then:
- Plug it in and point it at the crib.
- Tap **Dark screen**. The app keeps the screen on, so the camera keeps running,
  but at zero brightness.
- Optional: turn on **Guided Access** (Settings → Accessibility) so nobody can
  accidentally leave the app.

**Your phone:** open Baby Monitor → **Parent**, use the **same password**,
then **Start**. Allow notifications and local network access.

### If the nursery phone is one of your own

- Turn on **Do Not Disturb** on it (Control Center → Focus), so calls and
  messages don't ring in the nursery. The app keeps working.
- A phone call answered on the nursery phone pauses the monitoring until the
  call ends.
- An old iPhone or iPad works just as well as a nursery device, and then you
  can both have a parent phone. Any number of parents can watch at once.

### Make sure alerts get through at night

- **Sleep Focus / Do Not Disturb:** check that Settings → Notifications → Baby
  Monitor → **Time Sensitive Notifications** is on. To be extra safe, also add
  Baby Monitor to the allowed apps: Settings → Focus → Sleep → Apps.
- **Silent switch:** the live sound and the in-app alert tones play even with
  the silent switch on, because the app works like a music app. The
  notification sounds themselves follow the silent switch.
- **Don't swipe the app away** in the app switcher. That closes it and stops
  everything. Locking the phone or switching to other apps is fine.

### Tuning alerts

Watch the meter while your son sleeps normally. Drag the slider so the white
line sits a bit above that level. **…for at least** stops short noises, like a
cough or a car outside, from triggering an alert. After an alert there is a
30-second pause before the next one.

## Away from home (cellular)

1. Install **[Tailscale](https://tailscale.com/download/ios)** from the App
   Store on **both** phones. Sign in with the same account on both. It's free;
   a Google or Apple account works.
2. Start Baby Monitor on the nursery phone. It shows **"Away from home,
   connect to 100.x.y.z"**.
3. On your phone, tap **Leave**, enter that address under **Away from home**,
   then **Start** again. You only do this once.

That's it. At home the phones still find each other directly over Wi-Fi. When
your phone leaves the Wi-Fi, it reconnects through Tailscale within a few
seconds. Leave Tailscale switched on on both phones.

**Data saver** turns on by itself whenever your phone isn't on Wi-Fi (you'll
see a blue "Data saver" label):
- Sound is compressed, using about **35 MB per hour** (about 280 MB for an
  8-hour night) instead of about 115 MB per hour.
- Video is sent at 1 frame per second, and only while the app is open on
  screen.

You can now lock your phone. Sound keeps playing, and alerts arrive as
notifications. Video pauses while the phone is locked, to save battery, and
resumes when you open the app.

## Free or paid Apple account?

| | Free Apple ID | Apple Developer Program ($99/year) |
|---|---|---|
| Install from Xcode | ✅ | ✅ |
| **App keeps working for** | **7 days**, then reinstall from Xcode | 1 year |
| Time Sensitive Notifications | Usually available | ✅ |

With a free account the app **stops opening after 7 days** until you reinstall
it from Xcode. Because a baby monitor must work every night, either reinstall
it on a fixed day each week or get the paid membership.

## Good to know

- **Away from home** needs Tailscale on both phones. See
  [Away from home](#away-from-home-cellular). Without it, the phones only find
  each other on the same Wi-Fi.
- **Leaving Wi-Fi:** the connection switches to cellular automatically. The
  lost-contact alarm waits 15 seconds, so a normal switch doesn't trigger it.
- **Battery:** the nursery phone must be plugged in. A parent phone uses about
  as much battery as playing music all night, so charge it by the bed.
- **Phone calls** pause the sound. It resumes when the call ends; if it
  doesn't, open the app.
- **This app helps you keep an eye on your son. It is not a medical device.** It
  does not check breathing or movement, and Wi-Fi and phones can fail.

## How it works

```
 Nursery iPhone (Baby station)              Parent iPhones
 ┌──────────────────────────┐   Wi-Fi   ┌───────────────────────────┐
 │ mic  → 16 kHz PCM  ──────┼──────────▶│ AVAudioEngine (all night) │
 │ camera → JPEG ~8 fps ────┼──────────▶│ video while app is open   │
 │ sound level, heartbeat ──┼──────────▶│ noise + lost-contact      │
 │ Bonjour: _babymonitor    │  TLS-PSK  │   alerts → notifications  │
 └──────────────────────────┘           └───────────────────────────┘
```

- **Finding each other:** the baby station announces itself with Bonjour
  (`_babymonitor._tcp`) and listens on port 47820. Parents look for it on the
  Wi-Fi, and otherwise connect to its Tailscale address.
- **Data saver:** when the parent isn't on Wi-Fi it asks for 8 kHz G.711 µ-law
  sound (64 kbit/s instead of 256 kbit/s) and 1 video frame per second.
- **Security:** TLS 1.2 with a key derived from the family password (TLS-PSK),
  so only phones with the password can connect, and the audio and video are
  encrypted.
- **Staying awake:** a parent phone keeps its audio engine running all night.
  iOS lets apps that play audio keep running in the background, so the parent
  phone keeps receiving, can tell when the baby station goes quiet, and can
  post notifications itself.
- **Protocol:** each message is a 1-byte type, a 4-byte length, then the
  payload. See [`Core/Framing.swift`](BabyMonitor/Core/Framing.swift).

The platform-independent logic (message format, noise detection, lost-contact
watchdog) has tests:

```bash
cd ios
swiftc -o /tmp/logic-tests BabyMonitor/Core/Framing.swift BabyMonitor/Core/Detection.swift BabyMonitor/Core/Codec.swift Tests/main.swift && /tmp/logic-tests
```

GitHub Actions builds the app and runs these tests on every change
(`.github/workflows/ios.yml`).
