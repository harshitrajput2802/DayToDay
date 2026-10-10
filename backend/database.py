import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase

# Local default preserves the existing Windows workflow.
# On Render, set DATABASE_URL=sqlite:////var/data/DayToDay.db and attach a disk at /var/data.
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./DayToDay.db")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

class Base(DeclarativeBase):
    pass

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()