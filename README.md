# Day To Day

> **Spend Smart. Live Better!**

Day To Day is a personal income and expense tracker built with Flutter. All
transactions are stored in a local SQLite database on your device, so your
financial data is never sent to a server.

**Current version:** v1.0.2

---

## Features

### Dashboard
- **Summary cards** for Income, Expenses and Balance, with a count-up animation
  when values change.
- **Trend chips** on each card (for example `↑ 12%`) comparing the selected period with
  the previous period of the same length.
- **Tap to filter:** tap Income or Expenses to show only those transactions. The
  active card gets a highlighted border. Tap Balance to clear the filter.
- **Long-press for a breakdown:** a bottom sheet with the card's top 5 categories,
  amounts, percentages and progress bars. Everything beyond the top 5 is grouped
  as "Others".
- **Hide / show amounts:** the eye icon masks all amounts as `₹ ••••`.
- **Light and dark themes**, remembered between launches.

### Date filters
- Quick chips: Today, This week, This month, Last month, This year and Custom.
- The From / To fields and Search button appear only under **Custom**.
- The filter area collapses to a one-line summary such as `01 Oct – 17 Oct`.

### Transactions
- **Phones:** card-style rows with an inflow / outflow arrow, description,
  category, mode, date, coloured amount and running balance.
  - Income: down-left arrow on a green background.
  - Expense: up-right arrow on a light red background.
  - **Swipe right** to edit. **Swipe left** to repeat the transaction with
    today's date (with an Undo option).
  - **Tap** a card for details, including Edit, Repeat, Images and Delete.
  - **Long-press** a card to repeat it for today.
  - Pull down to refresh. A loading skeleton shows while data loads.
- **Wide screens:** a full 11-column table with Edit, Delete, Repeat and
  Image actions.
- **Search** by description.
- **Soft delete:** deleted transactions are flagged, not erased, so they still
  appear in backups.
- Attach up to two receipt images per transaction (stored inside the database).

### Menu
- The hamburger icon opens a side drawer with:
  - **Backup:** exports every transaction to an Excel (`.xlsx`) file in your
    Downloads folder and shows a notification you can tap to open it.
  - **About:** shows the app logo, name and version.

### Floating New button
- On phones, a floating **New** button adds a transaction. It shrinks to a
  `+` when you scroll down.

---

## Tech stack

- Flutter (Material 3)
- SQLite via [`sqflite`](https://pub.dev/packages/sqflite)
- Packages used: `intl`, `path`, `path_provider`, `excel`, `file_saver`,
  `open_filex`, `flutter_local_notifications`, `image_picker`,
  `flutter_image_compress`

---

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)
- Android Studio or the Android SDK command-line tools, to build for Android
- A connected Android device or an emulator
- Google Chrome, if you want to run it in the browser (see the note below)

Check your setup with:

```bash
flutter doctor
```

---

## How to run this project after downloading

### 1. Get the code

```bash
git clone <https://github.com/harshitrajput2802/DayToDay.git>
cd DAYTODAY
```

### 2. Run the Flutter app

```bash
cd frontend
flutter pub get
flutter run -d chrome
```

To run on a connected Android phone or emulator instead:

```bash
flutter devices          # list available devices
flutter run -d <device-id>
```

> **Note about Chrome:** the app stores data with `sqflite`, which is built for
> Android and iOS. On Chrome you will need the web database support from
> `sqflite_common_ffi_web`, and the Excel backup relies on `dart:io`, so it works
> best on Android. For the full experience, run on an Android device or emulator.

### 3. Build a release APK

```bash
cd frontend
flutter build apk --release
```

The APK is created at:

```
frontend/build/app/outputs/flutter-apk/app-release.apk
```

If your build talks to a hosted API, pass its address with `--dart-define`:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://daytoday-5d2d.onrender.com
```

> The current version of the app keeps all data on the device and does not read
> `API_BASE_URL`. This option is only needed if you add or restore a networked
> version.

### 4. Run the backend (optional)

The `backend/` folder holds a FastAPI service (`main.py`, `models.py`,
`schemas.py`, `database.py`) with its own SQLite file, `DayToDay.db`. The current
Flutter app does **not** depend on it.

```bash
cd backend

# create and activate a virtual environment (Windows)
python -m venv venv
venv\Scripts\activate

# macOS / Linux
# python3 -m venv venv
# source venv/bin/activate

pip install -r requirements.txt
uvicorn main:app --reload
```

The server starts at `http://127.0.0.1:8000`. FastAPI's interactive API docs
are at `http://127.0.0.1:8000/docs`.

---

## Project structure

```
DAYTODAY/
├── .gitignore
├── README.md
│
├── backend/                     # FastAPI service (optional, see note below)
│   ├── main.py                  # App entry point (uvicorn main:app)
│   ├── database.py              # Database connection / session setup
│   ├── models.py                # SQLAlchemy models
│   ├── schemas.py               # Pydantic request / response schemas
│   ├── requirements.txt         # Python dependencies
│   └── DayToDay.db              # SQLite database file
│
└── frontend/                    # Flutter app
    ├── lib/
    │   └── main.dart            # Whole app: local database, theme, screens
    ├── assets/
    │   └── icon/
    │       ├── DayToDay_Logo_brown.png   # Used in the About dialog
    │       └── DayToDay_Logo_blue.png
    ├── test/
    │   └── widget_test.dart
    ├── android/                 # Android project (Gradle, manifest, launcher icons)
    ├── ios/                     # iOS project
    ├── web/                     # Web shell (index.html, manifest.json, icons)
    ├── windows/                 # Windows desktop project
    ├── linux/                   # Linux desktop project
    ├── macos/                   # macOS desktop project
    ├── pubspec.yaml             # Flutter dependencies and asset list
    ├── pubspec.lock
    ├── analysis_options.yaml
    ├── README.md
    ├── README_DAYTODAY.md
    └── MOBILE_FIXES_README.md
```

Folders that are generated on your machine and should not be committed:
`.venv/`, `backend/venv/`, `__pycache__/`, `frontend/.dart_tool/`,
`frontend/build/`, `frontend/.idea/` and `frontend/android/.gradle/`.
Make sure they are listed in `.gitignore`.

> **Backend note:** the Flutter app in `frontend/lib/main.dart` stores everything
> in a local SQLite database on the device and does not call the backend. The
> `backend/` folder is a separate FastAPI service that you can run on its own.

Make sure the logo is listed under `assets:` in `frontend/pubspec.yaml`, because
the About dialog uses `assets/icon/DayToDay_Logo_brown.png`.

---

## Releasing a new version

1. Update `version:` in `pubspec.yaml`.
2. Update `kAppVersion` at the top of `lib/main.dart`, so the About dialog shows
   the same number.
3. Build with `flutter build apk --release`.

---

## Privacy

Your transactions, images and settings stay in a local SQLite database on your
device. Nothing is uploaded. Use **Backup** from the menu to keep your own
Excel copy.

---

## License

No actions permitted without permission.
