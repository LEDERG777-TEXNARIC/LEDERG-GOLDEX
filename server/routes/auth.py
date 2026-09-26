from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from server.db.session import SessionLocal
from server.models import User
from server.auth import hash_password, verify_password, make_token

router = APIRouter()

class AuthIn(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[a-zA-Z0-9_.-]+$")
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=1, max_length=80)

@router.post("/register")
def register(data: AuthIn):
    with SessionLocal() as db:
        if db.scalar(select(User).where(User.username == data.username.lower())):
            raise HTTPException(409, "Username already exists")
        user = User(username=data.username.lower(), display_name=data.display_name,
                    password_hash=hash_password(data.password))
        db.add(user); db.commit(); db.refresh(user)
        return {"access_token": make_token(user.id), "user": {"id": user.id, "username": user.username, "display_name": user.display_name}}

@router.post("/login")
def login(data: AuthIn):
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.username == data.username.lower()))
        if not user or not verify_password(data.password, user.password_hash):
            raise HTTPException(401, "Invalid credentials")
        return {"access_token": make_token(user.id), "user": {"id": user.id, "username": user.username, "display_name": user.display_name}}
