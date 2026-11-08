from datetime import date, datetime

from pydantic import BaseModel, ConfigDict

class TransactionCreate(BaseModel):
    TranDate: date
    Description: str
    Amount: float
    Type: str
    Mode: str
    Remarks: str | None = None
    Other: str | None = None
    CategoryName: str | None = None

class TransactionResponse(BaseModel):
    id: int
    TranDate: date
    Description: str
    Amount: float
    Type: str
    Mode: str
    Remarks: str | None
    Other: str | None
    CategoryName: str | None
    CreationDate: datetime

    model_config = ConfigDict(
        from_attributes=True
    )