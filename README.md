# 💰 DayToDay — Personal Expense & Income Tracker

> A modern personal finance application for tracking daily expenses, income, transactions, categories and financial reports.

**DayToDay** is a full-stack personal finance application built with **Flutter** and **FastAPI**. It provides a simple interface for recording and analysing personal transactions while supporting date-based filtering, invoice attachments, authentication and Excel backup/export.

---

## ✨ Features

* 💰 Track daily expenses
* 💵 Track income
* 📊 Dashboard with financial summaries
* 📅 Filter transactions by date range
* 🏷️ Categorise transactions
* 🧾 Attach invoice/receipt images
* 🔐 User authentication
* 🔑 Secure token-based authentication
* 📈 Financial reports and charts
* 📤 Export complete transaction data to Excel
* 🗑️ Safe transaction deletion
* 🌐 REST API architecture
* 📱 Flutter Android application
* 🖥️ Flutter Web/Desktop support
* 🐘 PostgreSQL database
* 🐳 Docker-based local development

---

# 🏗️ Architecture

```text
                    ┌─────────────────────────┐
                    │       Flutter App       │
                    │                         │
                    │ Android / Web / Desktop │
                    └────────────┬────────────┘
                                 │
                                 │ HTTPS / REST API
                                 ▼
                    ┌─────────────────────────┐
                    │       FastAPI API       │
                    │                         │
                    │ Authentication          │
                    │ Transactions            │
                    │ Dashboard               │
                    │ Reports                 │
                    │ Attachments             │
                    └────────────┬────────────┘
                                 │
                                 │ SQLAlchemy
                                 ▼
                    ┌─────────────────────────┐
                    │       PostgreSQL        │
                    │                         │
                    │ Users                   │
                    │ Transactions            │
                    │ Categories              │
                    │ Attachments              │
                    └─────────────────────────┘
```

---

# 🛠️ Technology Stack

## Frontend

* Flutter
* Dart
* Material 3
* Riverpod
* GoRouter
* Dio
* Flutter Secure Storage
* FL Chart
* Image Picker

## Backend

* Python
* FastAPI
* Uvicorn
* SQLAlchemy
* Pydantic
* Alembic
* PostgreSQL
* JWT
* Argon2 password hashing
* Boto3 / object-storage support where required
* Pytest

## Infrastructure

* Docker
* Docker Compose
* PostgreSQL

---

# 📁 Project Structure

```text
day_to_day/
│
├── backend/
│   ├── app/
│   │   ├── api/
│   │   ├── core/
│   │   ├── models/
│   │   ├── repositories/
│   │   ├── schemas/
│   │   ├── services/
│   │   └── main.py
│   │
│   ├── alembic/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── alembic.ini
│
├── frontend/
│   ├── android/
│   ├── ios/
│   ├── linux/
│   ├── macos/
│   ├── web/
│   ├── windows/
│   ├── lib/
│   ├── test/
│   └── pubspec.yaml
│
├── docker-compose.yml
├── .env.example
├── .gitignore
└── README.md
```

---

# 🚀 Getting Started

## Prerequisites

Install:

* Git
* Python 3.11+
* Flutter SDK
* Dart SDK
* Docker Desktop
* PostgreSQL (only required if running PostgreSQL outside Docker)

Verify:

```bash
git --version
python --version
flutter --version
docker --version
docker compose version
```

---

# ⚙️ Backend Setup

Navigate to the backend:

```bash
cd backend
```

Create a virtual environment:

```bash
python -m venv .venv
```

Activate it on Windows:

```powershell
.venv\Scripts\activate
```

Install dependencies:

```bash
pip install -r requirements.txt
```

Create your environment configuration:

```text
.env
```

Do **not** commit `.env`.

Use `.env.example` as the template.

---

# 🐘 Database Setup

Start PostgreSQL using Docker Compose:

```bash
docker compose up -d postgres
```

Run migrations:

```bash
cd backend
alembic upgrade head
```

---

# ▶️ Run FastAPI Backend

From the `backend` directory:

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

API:

```text
http://localhost:8000
```

Swagger documentation:

```text
http://localhost:8000/docs
```

OpenAPI:

```text
http://localhost:8000/openapi.json
```

Health check:

```text
http://localhost:8000/health
```

or the health endpoint configured by the current backend.

---

# 📱 Flutter Setup

Open another terminal:

```bash
cd frontend
```

Install packages:

```bash
flutter pub get
```

Check Flutter:

```bash
flutter doctor
```

Run the application:

```bash
flutter run
```

For Chrome:

```bash
flutter run -d chrome
```

For Windows:

```bash
flutter run -d windows
```

For Android:

```bash
flutter run -d android
```

---

# 🔗 API Configuration

The Flutter application needs the production or development FastAPI URL.

During local development:

```text
http://localhost:8000
```

For Android Emulator:

```text
http://10.0.2.2:8000
```

For production:

```text
https://YOUR-BACKEND-NAME.onrender.com
```

The production API URL should be configured through the application's API configuration rather than hard-coded throughout the project.

---

# 📊 Transaction Management

DayToDay supports:

```text
Income
Expense
   │
   ├── Category
   ├── Amount
   ├── Date
   ├── Description
   ├── Payment method
   └── Invoice / Receipt
```

Transactions can be filtered using a selected date range.

Example:

```text
01 October 2026
        ↓
10 October 2026

       ↓

Only transactions inside this period
```

---

# 📤 Excel Backup

DayToDay provides a backup/export mechanism.

The user can export the complete transaction data into an Excel file.

Example:

```text
DayToDay_Backup_2026-10-10.xlsx
```

The generated backup contains the application's relevant financial data and can be stored by the user independently.

> Generated personal backup files are intentionally excluded from Git using `.gitignore`.

---

# 🔐 Security

The application uses:

* JWT authentication
* Secure password hashing
* Secure token storage
* Environment variables for secrets
* Database authentication
* CORS configuration

### Never commit:

```text
.env
JWT secrets
database passwords
API keys
private keys
Android signing keys
personal financial data
generated backups
```

---

# 🐳 Docker

Start the complete local infrastructure:

```bash
docker compose up -d --build
```

Check running containers:

```bash
docker compose ps
```

View backend logs:

```bash
docker compose logs -f backend
```

Stop services:

```bash
docker compose down
```

Stop and remove local database volumes:

```bash
docker compose down -v
```

> `docker compose down -v` permanently removes local Docker database volumes. Use it carefully.

---

# 🧪 Testing

Backend tests:

```bash
cd backend
pytest
```

Flutter analysis:

```bash
cd frontend
flutter analyze
```

Flutter tests:

```bash
flutter test
```

---

# ☁️ Production Deployment

The planned production architecture is:

```text
                Internet
                   │
                   ▼
          ┌─────────────────┐
          │  Flutter Web    │
          │    Frontend     │
          └────────┬────────┘
                   │ HTTPS
                   ▼
          ┌─────────────────┐
          │     Render      │
          │    FastAPI      │
          └────────┬────────┘
                   │
                   ▼
          ┌─────────────────┐
          │   PostgreSQL    │
          │   Production DB │
          └─────────────────┘
```

The backend can be deployed as a Render Web Service.

The Flutter application can be built as a web application and deployed separately.

The production Flutter application must point to the deployed HTTPS FastAPI URL.

---

# 📦 Android Build

After production deployment and testing:

```bash
cd frontend
```

Build APK:

```bash
flutter build apk --release
```

Build App Bundle:

```bash
flutter build appbundle --release
```

Generated files are normally located under:

```text
frontend/build/app/outputs/flutter-apk/
```

and:

```text
frontend/build/app/outputs/bundle/release/
```

---

# 🖼️ Application Branding

The application uses the **DayToDay** financial tracking identity with a wallet/₹ based application icon.

The Android launcher icon should be generated using Flutter's launcher-icon tooling rather than manually replacing individual Android icon files.

Recommended production setup:

```text
assets/
└── icon/
    └── daytoday_icon.png
```

Then configure the Flutter launcher icon generation.

---

# 🗺️ Deployment Roadmap

The project will be deployed in this order:

```text
1. Clean Git repository
        ↓
2. GitHub
        ↓
3. Add production-safe environment configuration
        ↓
4. Deploy PostgreSQL
        ↓
5. Deploy FastAPI backend → Render
        ↓
6. Test API
        ↓
7. Configure Flutter production API URL
        ↓
8. Build Flutter Web
        ↓
9. Deploy Flutter Web
        ↓
10. Add application icon
        ↓
11. Test complete production application
        ↓
12. Configure Android release
        ↓
13. Build APK
        ↓
14. Build AAB for Play Store
```

---

# 👨‍💻 Author

**Harshit Rajput**

B.Tech Computer Science & Engineering

---

# 📄 License

This project is currently intended for personal/educational use.

A formal open-source license can be added later if the project is released publicly.