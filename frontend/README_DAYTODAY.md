# DayToDay — Expense Tracker

DayToDay is a personal income and expense tracker built with Flutter and FastAPI. It supports transaction management, date filtering, running balances, and Excel exports.

## Features
- Add, edit, and soft-delete transactions
- Filter transactions by date range
- Income, expense, and net-balance summaries
- Running transaction balance
- Excel backup export, including soft-deleted records
- Flutter Web and Android builds

## Stack
- Frontend: Flutter / Dart
- Backend: FastAPI / Python
- Database: SQLite (configure persistent storage for hosted deployment)
- Excel: openpyxl

## Run locally

### Backend
```powershell
cd backend
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

### Frontend
```powershell
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## Android release APK
Build with the deployed HTTPS backend URL:
```powershell
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-BACKEND.onrender.com
```
APK output: `build/app/outputs/flutter-apk/app-release.apk`.

## Important data note
Do not commit your database, `.env` files, or exported personal Excel backups. Render's default filesystem is ephemeral; configure persistent storage or a managed database before storing important real transactions in production.
