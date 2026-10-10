from datetime import date, datetime
from io import BytesIO

from fastapi import Depends, FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

from sqlalchemy import select
from sqlalchemy.orm import Session

from database import Base, engine, get_db
from models import Transaction
from schemas import TransactionCreate, TransactionResponse

from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment

# --------------------------------------------------
# CREATE DATABASE TABLES
# --------------------------------------------------

Base.metadata.create_all(bind=engine)


# --------------------------------------------------
# FASTAPI
# --------------------------------------------------

app = FastAPI(
    title="Day To Day API",
    version="1.0.0",
)


# --------------------------------------------------
# CORS
# --------------------------------------------------

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://daytwoday.netlify.app",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --------------------------------------------------
# HEALTH CHECK
# --------------------------------------------------

@app.get("/")
def home():
    return {
        "message": "Hello Welcome"
    }


@app.get("/api/health")
def health():
    return {
        "status": "ok"
    }


# --------------------------------------------------
# CREATE TRANSACTION
# --------------------------------------------------

@app.post(
    "/transactions",
    response_model=TransactionResponse,
)
def create_transaction(
    transaction: TransactionCreate,
    db: Session = Depends(get_db),
):
    new_transaction = Transaction(
        TranDate=transaction.TranDate,
        Description=transaction.Description,
        Amount=transaction.Amount,
        Type=transaction.Type,
        Mode=transaction.Mode,
        Remarks=transaction.Remarks,
        Other=transaction.Other,
        CategoryName=transaction.CategoryName,
    )

    db.add(new_transaction)
    db.commit()
    db.refresh(new_transaction)

    return new_transaction


# --------------------------------------------------
# GET ALL TRANSACTIONS
# --------------------------------------------------

@app.get(
    "/transactions",
    response_model=list[TransactionResponse],
)
def get_transactions(
    db: Session = Depends(get_db),
):
    statement = (
    select(Transaction)
    .where(Transaction.IsDeleted.is_(False))
    .order_by(
        Transaction.TranDate.desc(),
        Transaction.id.desc(),
        )
    )

    transactions = db.scalars(statement).all()

    return transactions


# --------------------------------------------------
# GET TRANSACTIONS BY DATE
# --------------------------------------------------

@app.get(
    "/transactions/search",
    response_model=list[TransactionResponse],
)
def search_transactions(
    from_date: date = Query(...),
    to_date: date = Query(...),
    db: Session = Depends(get_db),
):
    statement = (
    select(Transaction)
    .where(
        Transaction.IsDeleted.is_(False),
        Transaction.TranDate >= from_date,
        Transaction.TranDate <= to_date,
    )
    .order_by(
        Transaction.TranDate.desc(),
        Transaction.id.desc(),
        )
    )

    transactions = db.scalars(statement).all()

    return transactions



@app.get("/transactions/summary")
def transaction_summary(
    from_date: date | None = Query(default=None),
    to_date: date | None = Query(default=None),
    db: Session = Depends(get_db),
):
    """Return active-transaction totals, optionally restricted to a date range."""
    if from_date and to_date and from_date > to_date:
        raise HTTPException(
            status_code=400,
            detail="from_date cannot be after to_date",
        )

    conditions = [Transaction.IsDeleted.is_(False)]
    if from_date:
        conditions.append(Transaction.TranDate >= from_date)
    if to_date:
        conditions.append(Transaction.TranDate <= to_date)

    statement = select(Transaction).where(*conditions)
    records = db.scalars(statement).all()

    total_income = sum(
        float(record.Amount or 0)
        for record in records
        if (record.Type or "").strip().lower() == "income"
    )
    total_expenses = sum(
        float(record.Amount or 0)
        for record in records
        if (record.Type or "").strip().lower() == "expense"
    )

    return {
        "from_date": from_date.isoformat() if from_date else None,
        "to_date": to_date.isoformat() if to_date else None,
        "transaction_count": len(records),
        "total_income": round(total_income, 2),
        "total_expenses": round(total_expenses, 2),
        "net_balance": round(total_income - total_expenses, 2),
    }


@app.get("/transactions/export")
def export_transactions(db: Session = Depends(get_db)):
    # Fetch ALL transactions, regardless of the UI date filter.
    statement = select(Transaction).order_by(
        Transaction.TranDate.desc(),
        Transaction.id.desc(),
    )
    transactions = db.scalars(statement).all()

    
    # Calculate running balance in chronological order.
    # Soft-deleted transactions do not affect the balance.
    chronological_transactions = sorted(
        transactions,
        key=lambda t: (t.TranDate, t.id),
    )

    running_balance = 0.0
    balance_by_id = {}

    for transaction in chronological_transactions:
        amount = float(transaction.Amount or 0)

        if not transaction.IsDeleted:
            transaction_type = (transaction.Type or "").strip().lower()

            if transaction_type == "income":
                running_balance += amount
            elif transaction_type == "expense":
                running_balance -= amount

        balance_by_id[transaction.id] = round(running_balance, 2)

    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "Transactions"

    headers = [
        "Tran No",
        "TranDate",
        "Description",
        "Amount",
        "Type",
        "Mode",
        "Remarks",
        "Other",
        "CategoryName",
        "CreationDate",
        "IsDeleted",
        "Balance",
    ]
    worksheet.append(headers)

    # Format the header row.
    for cell in worksheet[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill(
            fill_type="solid",
            fgColor="1565C0",
        )
        cell.alignment = Alignment(horizontal="center")

    # Add all database records.
    for transaction in transactions:
        worksheet.append([
            transaction.id,
            transaction.TranDate,
            transaction.Description,
            transaction.Amount,
            transaction.Type,
            transaction.Mode,
            transaction.Remarks,
            transaction.Other,
            transaction.CategoryName,
            transaction.CreationDate,
            bool(transaction.IsDeleted),
            balance_by_id[transaction.id],
        ])

    # Improve column widths.
    widths = [12, 15, 32, 15, 15, 15, 25, 25, 20, 23, 15, 16]

    for index, width in enumerate(widths, start=1):
        worksheet.column_dimensions[
            worksheet.cell(row=1, column=index).column_letter
        ].width = width

    worksheet.freeze_panes = "A2"
    worksheet.auto_filter.ref = worksheet.dimensions

    # Generate the workbook in memory.
    output = BytesIO()
    workbook.save(output)
    output.seek(0)

    # Create a backup filename with a timestamp.
    backup_filename = (
        f"Transactions_backup_till_"
        f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.xlsx"
    )

    return StreamingResponse(
        output,
        media_type=(
            "application/vnd.openxmlformats-officedocument."
            "spreadsheetml.sheet"
        ),
        headers={
            "Content-Disposition":
                f'attachment; filename="{backup_filename}"'
        },
    )

@app.put(
    "/transactions/{transaction_id}",
    response_model=TransactionResponse,
)
def update_transaction(
    transaction_id: int,
    transaction: TransactionCreate,
    db: Session = Depends(get_db),
):
    existing_transaction = db.get(Transaction, transaction_id)

    if existing_transaction is None or existing_transaction.IsDeleted:
        raise HTTPException(
            status_code=404,
            detail="Transaction not found",
        )

    existing_transaction.TranDate = transaction.TranDate
    existing_transaction.Description = transaction.Description
    existing_transaction.Amount = transaction.Amount
    existing_transaction.Type = transaction.Type
    existing_transaction.Mode = transaction.Mode
    existing_transaction.Remarks = transaction.Remarks
    existing_transaction.Other = transaction.Other
    existing_transaction.CategoryName = transaction.CategoryName

    # Preserve id, CreationDate, and IsDeleted.
    db.commit()
    db.refresh(existing_transaction)

    return existing_transaction


@app.delete("/transactions/{transaction_id}")
def soft_delete_transaction(
    transaction_id: int,
    db: Session = Depends(get_db),
):
    transaction = db.get(Transaction, transaction_id)

    if transaction is None or transaction.IsDeleted:
        raise HTTPException(
            status_code=404,
            detail="Transaction not found",
        )

    transaction.IsDeleted = True
    db.commit()

    return {
        "message": "Transaction moved to deleted records",
        "id": transaction.id,
    }
