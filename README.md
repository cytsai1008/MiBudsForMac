# MiBuds for Mac

A macOS menu bar app for Xiaomi and Redmi earbuds. It shows the battery level of each earbud and the case, and switches noise control.

Tested on **Redmi Buds 6 Lite**. Other models that use the Xiaomi Earbuds app will probably work, but nobody has tested them. See [Device support](#device-support).

This project has no connection to Xiaomi. It works with the earbuds' Bluetooth protocol, which we found by decompiling the Xiaomi Earbuds Android app (version 1.39.0).

## Features

- Battery level and charging state for the left earbud, the case and the right earbud.
- Noise control: Noise Cancelling, Off, Transparency.
- Noise level, on models that have levels. The app shows only the levels your model has.
- Right-click the menu bar icon to turn on **Open at Login**, or to quit.

## Requirements

- macOS 13 or later, on Apple Silicon or Intel.
- Earbuds paired with the Mac and connected.

## Install

### Homebrew

```sh
brew install --cask cytsai1008/tap/mibuds-for-mac
```

Homebrew installs `MiBuds.app` in `/Applications`. The app does not have an Apple Developer ID signature, so before the first launch, run:

```sh
xattr -dr com.apple.quarantine /Applications/MiBuds.app
```

To update, run `brew upgrade --cask mibuds-for-mac`.

### Manual

1. Download `MiBuds.zip` from [Releases](../../releases) and unzip it.
2. Move `MiBuds.app` to `/Applications` or `~/Applications`.
3. Open the app. The app does not have an Apple Developer ID signature, so macOS blocks it the first time. To open it, right-click the app, select **Open**, then select **Open** again. You can also run this command one time:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MiBuds.app
   ```

4. When macOS asks for Bluetooth access, select **Allow**.

## Use

- **Left-click** the earbuds icon in the menu bar to open the panel. The panel shows battery and noise control.
- **Right-click**, or Control-click, the icon to open the menu. It has **Open at Login** and **Quit MiBuds**.

macOS manages the Bluetooth connection. When macOS connects a device with "buds", "redmi" or "xiaomi" in its name, the app opens its channel to it. When macOS disconnects the earbuds, the app shows "Not connected". The app refreshes the battery level every 60 seconds. When you change a setting on the earbuds, for example with a tap, the app updates at once.

## Build from source

You need the Xcode command line tools. The app needs no other packages.

```sh
./build.sh        # builds build/MiBuds.app and build/MiBuds.zip (universal, macOS 13+)
./build.sh test   # runs the protocol self-test
```

## How it works

| Part | Detail |
|---|---|
| Connection | Bluetooth RFCOMM channel for service UUID `0xFD2D`. If the earbuds do not have that service, the app tries standard SPP, and then Bluetooth LE service `0xAF00`. |
| Packet | `FE DC BA` · flags · opcode · length (2 bytes) · payload · `EF` |
| Login | Each side sends a 16-byte random challenge, and the other side answers with Bluetooth E21 (SAFER+). The address is fixed: `11 22 33 33 22 11`. The self-test checks our code against output from the original native library. |
| Battery | Opcode `0x02` (get target info), attribute 7. One byte each for left, right and case. Bit 7 means charging, and the low 7 bits are the percent. |
| Noise mode | Opcode `0x08` (set target info), value `[02, 04, mode]`. Mode 0 is off, 1 is noise cancelling, 2 is transparency. |
| Noise level | Opcode `0xF2` (set device config), config 11, value `[mode, level]`. |

Source files:

- `Sources/Protocol.swift`: packet format, login, payloads and the table of models.
- `Sources/Links.swift`: the Bluetooth connections (classic RFCOMM and LE).
- `Sources/Buds.swift`: the session, the login steps and the commands.
- `Sources/App.swift`: the menu bar item and the panel.

## Device support

The Xiaomi Earbuds app downloads its list of models and their features from Xiaomi's server. `Sources/Protocol.swift` has a copy of the noise-level part of that list, taken on 2026-11-04.

| Status | What |
|---|---|
| Tested | Redmi Buds 6 Lite: battery and noise mode, over RFCOMM `0xFD2D` |
| Not tested | Noise levels on other models |
| Not tested | Login over standard SPP, and the Bluetooth LE connection |
| Not tested | "ANC turbo" switch for ZMI (ZiMi) earbuds. The on/off values are a guess. |
| Not added | JieLi, 1MORE and ZiMi alarm-clock commands. These have no battery or noise feature. |

Code that has not been tested has an `UNTESTED` comment. The comment names the decompiled source file and the hardware the code is for. If you test a model, please open an issue and include the result.
