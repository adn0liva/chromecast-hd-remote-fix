# Chromecast HD: the remote disconnects and never comes back

> **Versión en español:** [README.es.md](README.es.md)

Automatic fix for the **Chromecast with Google TV (HD)** when the Bluetooth remote stops
working and only comes back after clearing the Bluetooth app's data and pairing it again.

## Symptoms

- The remote stops responding (arrows, OK, Home, voice). Sometimes several times a day.
- Restarting the Chromecast doesn't always fix it.
- What does work, but gets tiring: Settings → Apps → Bluetooth → **Clear data** and pair
  the remote again.
- The TV power and volume buttons keep working (those use infrared).

## The cause

The remote disconnects on its own every now and then (normal for low-energy Bluetooth
remotes). After that, the Chromecast should keep **listening** for the remote so it can
reconnect as soon as you press a button. It does this by adding the remote to a list in
the Bluetooth chip (the *LE accept list*).

On the Chromecast HD that list is sometimes **left empty** after the disconnect. The
remote is still paired, but the Chromecast no longer accepts its reconnection. That's
why:

- **Clearing the Bluetooth data** fixed it: it restarts Bluetooth (that's the part that
  fixes it) and also deletes the pairing (that part was unnecessary).
- **Restarting only Bluetooth** is enough, and you don't have to pair again.

What it looks like in `dumpsys bluetooth_manager` (remote paired, disconnected and not
in the list):

```
shim::legacy::hid   0: addr:xx:xx:xx:xx:yy:zz ... state:BTHH_CONN_STATE_DISCONNECTED
shim::acl Shadow le accept list              size:0   controller_max_size:255
```

And the hint that the stack got out of sync, when Bluetooth is turned off:

```
acl.cc:189 Remove: Unknown device being removed from acceptlist:xx:xx:xx:xx:yy:zz
```

On the device where this was diagnosed, the remote had been unable to reconnect for
**19 days** in that state. After restarting only Bluetooth, the list contained the
remote again (`size:1`) and it reconnected on the first button press.

**Ruled out** in that diagnosis: remote batteries (good level), remote firmware (26.7),
Wi‑Fi (5 GHz, good signal), a USB‑C hub with Ethernet (it happened on Wi‑Fi too) and
Bluetooth crashes (0 crashes). A Chromecast with Google TV **4K** in the same house never
had the problem.

## The fix: "Vigilante del control" (remote watchdog)

A minimal app with no UI that:

1. **Starts on its own** every time the Chromecast boots.
2. Reads `dumpsys bluetooth_manager` every **30 seconds**.
3. If the remote is **paired, disconnected and the list is empty** in **two checks in a
   row**, it restarts Bluetooth (at most once every 3 minutes).
4. Keeps a log of what it does.

In everyday use you won't notice anything: the fault shows up while the remote is idle,
and the watchdog fixes it before you pick the remote up again.

Technical details:

- It needs the `android.permission.DUMP` permission to read the Bluetooth state. That
  permission can't be requested from the app: it's granted **once via ADB** and survives
  reboots.
- It restarts Bluetooth with `BluetoothAdapter.disable()/enable()`. Since Android 13 that
  is only allowed for apps targeting API 32 or lower, so the app deliberately declares
  `targetSdkVersion 30`.
- Only the system and ADB can send it commands (the receiver requires the `DUMP`
  permission); other apps can't make it restart Bluetooth.
- It needs no root, no internet and no computer left running.

## Results

Measured on the Chromecast HD where the problem was diagnosed, over 8 days (October 20–28,
2026), from the app's own log:

| | |
| --- | --- |
| Faults fixed automatically | **66** (about 8 per day, up to 17 in a single day) |
| Fixes that worked | **66 of 66**: after every restart the Chromecast was listening for the remote again (`tras reinicio: ok`) |
| False alarms avoided | 2: the fault cleared on its own within 30 s, and the two-check rule skipped an unnecessary restart |
| Survived a Chromecast reboot | Yes, it started on its own |
| Bluetooth crashes | 0 |

Without the app, the remote would have stopped working roughly 66 times that week, each
time needing the "clear data and pair again" routine. In practice nothing was noticeable:
the fault shows up while the remote is idle and gets fixed before it's picked up again.

## Installation without AI (step by step)

You need a computer on the **same network** as the Chromecast. It takes about 10 minutes.

### 1. Install ADB on the computer

- **macOS:** `brew install android-platform-tools`
- **Windows / Linux:** download the *SDK Platform-Tools* from
  <https://developer.android.com/tools/releases/platform-tools> and unzip them.

### 2. Enable debugging on the Chromecast

1. **Settings → System → About → Android TV OS build**: press OK **7 times** until it
   says you're a developer.
2. **Settings → System → Developer options**: turn on **USB debugging** and **Wireless
   debugging**.

> **If your Chromecast is connected with a network cable**, wireless debugging shows up
> disabled: Android only allows it over **Wi‑Fi**. Unplug the cable while you install;
> you can plug it back in afterwards.

> If the remote doesn't work for navigating the menus, use the **Google Home** or
> **Google TV** phone app as a remote, or your TV's remote (HDMI‑CEC).

### 3. Pair the computer with the Chromecast

Open **Wireless debugging**. You'll see **two different ports**, and they're easy to mix
up:

| Where it's shown | What it's for |
| --- | --- |
| Main *Wireless debugging* screen | **Connecting** (`adb connect`) |
| *Pair device with pairing code* dialog (next to the 6-digit code) | **Pairing** (`adb pair`), only once |

With the pairing dialog open:

```bash
adb pair IP:PAIRING_PORT CODE
adb connect IP:MAIN_PORT
adb devices
```

`adb devices` should list the Chromecast as `device`.

> **Don't run `adb connect` against the pairing port.** That service handles one
> connection at a time: it gets taken and pairing with the code hangs.

### 4. (Optional) Confirm you have this fault

While the remote is **not** working:

```bash
adb shell dumpsys bluetooth_manager | grep -E "BTHH_CONN_STATE|Shadow le accept list"
```

If you see `BTHH_CONN_STATE_DISCONNECTED` and `Shadow le accept list ... size:0`, it's this
fault. To check that restarting Bluetooth fixes it:

```bash
adb shell cmd bluetooth_manager disable
adb shell cmd bluetooth_manager enable
```

Press a button on the remote twice: it should work again (the first press wakes it up
and reconnects it; the second one reaches the TV).

### 5. Install the app

Download `rcu-watchdog.apk` from this repository's **Releases** section (or build it,
see below) and run:

```bash
adb install -r rcu-watchdog.apk
adb shell pm grant com.adan.rcuwatchdog android.permission.DUMP
adb shell am broadcast -a com.adan.rcuwatchdog.START -n com.adan.rcuwatchdog/.BootReceiver -f 0x20
```

The third command starts it for the first time. From then on it starts by itself on
every boot.

### 6. Verify

```bash
adb shell pidof com.adan.rcuwatchdog
adb shell cat /sdcard/Android/data/com.adan.rcuwatchdog/files/vigilante.log
```

You should get a process number and a log containing `vigilante iniciado` (watchdog
started) and `estado: ok` (status: ok).

To test that it can restart Bluetooth (the remote disconnects for a moment and comes
back when you press a button):

```bash
adb shell am broadcast -a com.adan.rcuwatchdog.TEST_RESTART -n com.adan.rcuwatchdog/.BootReceiver
```

The log shows `prueba manual -> reinicio Bluetooth` (manual test -> Bluetooth restart)
followed by `tras reinicio: ok` (after restart: ok).

Done. You can turn debugging off if you like; the app doesn't need it. (On this model,
wireless debugging turns itself off on reboot anyway.)

## Installation with help from Claude

With [Claude Code](https://claude.com/claude-code) on a computer on the same network,
enable debugging (step 2), open the pairing dialog and ask something like:

> I have a Chromecast HD with the problem described in this repository's README
> (`<repo URL>`). Read the README. Connect to my Chromecast over ADB: pairing at
> `IP:PORT` with code `CODE`, connection at `IP:MAIN_PORT`. Before installing anything,
> check with `dumpsys bluetooth_manager` whether I have this fault and explain what you
> find. If I do, install the app following "Installation without AI" and verify it's
> running.

That's how it was solved originally: diagnosis with `dumpsys` and `logcat`, a test
restarting only Bluetooth, a watchdog script and, finally, this app so it would survive
reboots.

## Checking the status later

```bash
./scripts/estado.sh IP:MAIN_PORT
```

Shows whether the app is running, whether it has the permission, the remote's state and
the log (labels are in Spanish). Lines reading
`control desconectado y fuera de la lista de escucha -> reinicio Bluetooth` (remote
disconnected and out of the accept list -> Bluetooth restart) are the times the watchdog
fixed the fault on its own.

If the Chromecast has rebooted, you need to pair again (step 3).

## Building from source

You need the Android SDK (build-tools and a platform) and JDK 17 or newer. With
[Android Studio](https://developer.android.com/studio) installed you already have both.

```bash
./app/build.sh
```

It produces `app/build/rcu-watchdog.apk` without Gradle (`javac` → `d8` → `aapt2` →
`zipalign` → `apksigner`). The first time, it creates your own signing key at
`app/signing.jks`, which is not committed to the repository. **Keep it**: to update the
installed app you must sign with the same key. With a different key, Android makes you
uninstall first and repeat the `pm grant`.

If your SDK or JDK live somewhere else, set `ANDROID_HOME` and `JAVA_HOME`.

## Uninstalling

```bash
adb uninstall com.adan.rcuwatchdog
```

Or from **Settings → Apps → See all apps → Vigilante del control → Uninstall**.

## Plan B without a computer

If the remote ever fails again and you don't have the app or a computer at hand:

**Settings → Apps → See all apps → Show system apps → Bluetooth → Force stop** (not
"Clear data").

That restarts Bluetooth without losing the pairing. Then press a button on the remote
twice.

## Things to keep in mind

- **Don't use "Force stop" on *Vigilante del control*.** Android doesn't deliver the
  boot notification to a force-stopped app: it would stop starting on its own until you
  launch it again with the `am broadcast ... START` from step 5.
- Restarting Bluetooth briefly drops **all** of the Chromecast's Bluetooth devices
  (headphones, gamepads), not just the remote.
- If the Chromecast is in **deep standby**, the watchdog pauses along with it. If the
  remote ever can't wake it up, turn the TV on with its own remote and wait a minute.
- Tested on a **Chromecast HD**, Android TV 14, build `UTTC.250917.004`, with the
  "Chromecast Remote" (firmware 26.7). The remote's name is hard-coded
  (`REMOTE_NAME` in `WatchdogService.java`).
- If a Google update fixes the fault, the watchdog will simply never act.

## Layout

```
app/
  AndroidManifest.xml        manifest (targetSdk 30, permissions, start on boot)
  build.sh                   build without Gradle
  src/com/adan/rcuwatchdog/
    BootReceiver.java        starts the service on boot (or when told by adb)
    WatchdogService.java     30-second check and Bluetooth restart
scripts/
  estado.sh                  app status and log via adb
  rcu_watchdog.sh            same logic as a shell script (no app install;
                             lives until the Chromecast's next reboot)
```

## License

[MIT](LICENSE). Use it at your own risk: the app restarts the Chromecast's Bluetooth and
comes with no warranty of any kind.
