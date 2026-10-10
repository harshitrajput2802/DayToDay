# DayToDay frontend fixes

This folder is a replacement frontend source package based on the ZIP you uploaded. Copy/merge its contents into your existing `D:\DayToDay\frontend` folder, backing up the current folder first.

## Included fixes
- Default API URL uses `https://daytoday-5d2d.onrender.com`; build-time `--dart-define=API_BASE_URL=...` still overrides it.
- Root health/message request uses the same configured API URL.
- Android INTERNET permission added.
- Launcher label and web/PWA title changed to DayToDay.
- Replaced Android launcher and web icons with the provided rupee-wallet icon.
- Income, Expenses and Balance use compact horizontal cards on mobile.
- Date filter is vertically aligned on mobile, with a full-width apply button.
- Add/Edit form stacks labels and fields on mobile and places Save/Update and Refresh after every field.
- Backup success message shows the returned save path when the plugin provides one, otherwise instructs the user to check Android's save location.

## Rebuild
```powershell
cd D:\DayToDay\frontend
flutter pub get
flutter analyze
flutter build apk --release --dart-define=API_BASE_URL=https://daytoday-5d2d.onrender.com
```

APK: `build\app\outputs\flutter-apk\app-release.apk`

Note: I could not run Flutter build/analyze in this environment. Please run the commands above before installing. For Android file export, confirm the plugin returns a location and test the result in Downloads or the Android file picker on your device.
