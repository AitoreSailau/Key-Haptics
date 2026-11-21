# KeyHaptics

A tiny macOS menu bar app that makes your MacBook trackpad vibrate while you type, and flashes the keyboard backlight.

- **Enter** – long, fading vibration
- **Space** – a quick series of pulses (3 by default)
- **Other keys** – optional light click
- Keyboard backlight goes off instantly on Enter/Space and fades back in smoothly
- Everything is configurable in **⌨︎ → Settings…** (effect, strength, pulse count, gap, fade length, backlight)

> MacBooks have no vibrating keyboard – the feedback comes from the trackpad's Taptic Engine.

## Install

1. Download `KeyHaptics.zip` from [Releases](../../releases) (or from the latest **Actions** run → Artifacts).
2. Unzip, drag `KeyHaptics.app` to `/Applications`.
3. The app is not notarized. First launch: right-click → **Open** → **Open**.
   If macOS says the app is damaged: `xattr -dr com.apple.quarantine /Applications/KeyHaptics.app`
4. Grant **System Settings → Privacy & Security → Input Monitoring** to KeyHaptics, then relaunch it.

Requires macOS 12+ and a MacBook with a Force Touch trackpad (2015 or newer).

## Build

```bash
./build.sh          # universal app in ./build/KeyHaptics.app
```

Needs Xcode Command Line Tools (`xcode-select --install`). Pushing a tag like `v1.0` builds the app on GitHub Actions and attaches `KeyHaptics.zip` to a release.

## How it works / caveats

- Key presses are observed with a listen-only `CGEventTap` (needs Input Monitoring). Nothing is logged or sent anywhere.
- Haptics use the private `MultitouchSupport` framework, because the public `NSHapticFeedbackManager` only fires while a finger touches the trackpad. If the private call fails, the app falls back to the public API (the menu shows which mode is active).
- Backlight uses the private `CoreBrightness` `KeyboardBrightnessClient`. It can break on any macOS update, and it will not work if the backlight is off.
- Private APIs mean this app can't be shipped on the App Store.

## По-русски

Menu bar приложение для Mac: при печати трекпад вибрирует (Enter — длинная затухающая вибрация, пробел — серия быстрых), а подсветка клавиатуры на Enter/пробел мгновенно гаснет и плавно загорается. Всё настраивается в меню ⌨︎ → «Настройки…». Установка: скачай `KeyHaptics.zip` из Releases, открой правым кликом → «Открыть» и дай доступ Input Monitoring.

## License

MIT
