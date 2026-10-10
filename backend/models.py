from datetime import date, datetime

from sqlalchemy import Boolean, Date, DateTime, Float, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from database import Base

class Transaction(Base):
    __tablename__ = "Transactions"

    id: Mapped[int] = mapped_column(
        Integer,
        primary_key=True,
        autoincrement=True,
    )

    TranDate: Mapped[date] = mapped_column(
        Date,
        nullable=False,
    )

    Description: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )

    Amount: Mapped[float] = mapped_column(
        Float,
        nullable=False,
    )

    Type: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
    )

    Mode: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
    )

    Remarks: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )

    Other: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )

    CategoryName: Mapped[str | None] = mapped_column(
        String(100),
        nullable=True,
    )

    CreationDate: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )

    IsDeleted: Mapped[bool] = mapped_column(
    Boolean,
    default=False,
    nullable=False,
    server_default="0",
    )