from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from server.db.session import SessionLocal
from server.models import User
from server.auth import hash_password, verify_password, make_token, current_user

router = APIRouter()
USERNAME = r"^[a-zA-Z0-9_.-]+$"

class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=USERNAME)
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=1, max_length=80)

class LoginIn(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=USERNAME)
    password: str = Field(min_length=8, max_length=128)

class PasswordIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)

def user_payload(user: User):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "has_avatar": bool(user.avatar_path),
        "created_at": user.created_at.isoformat() if user.created_at else None,
    }

@router.post("/register")
def register(data: RegisterIn):
    username = data.username.strip().lower()
    display_name = data.display_name.strip()
    if not display_name:
        raise HTTPException(422, "Display name is required")
    with SessionLocal() as db:
        if db.scalar(select(User.id).where(User.username == username)):
            raise HTTPException(409, "Username already exists")
        user = User(username=username, display_name=display_name, password_hash=hash_password(data.password))
        db.add(user)
        db.commit()
        db.refresh(user)
        return {"access_token": make_token(user.id, user.session_version), "user": user_payload(user)}

@router.post("/login")
def login(data: LoginIn):
    username = data.username.strip().lower()
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.username == username))
        if not user or not verify_password(data.password, user.password_hash):
            raise HTTPException(401, "Invalid username or password")
        return {"access_token": make_token(user.id, user.session_version), "user": user_payload(user)}

@router.post("/password")
def change_password(data: PasswordIn, me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user or not verify_password(data.current_password, user.password_hash):
            raise HTTPException(400, "Current password is incorrect")
        if data.current_password == data.new_password:
            raise HTTPException(400, "New password must be different")
        user.password_hash = hash_password(data.new_password)
        user.session_version += 1
        db.commit()
        return {"access_token": make_token(user.id, user.session_version)}

@router.post("/logout-all")
def logout_all(me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user:
            raise HTTPException(404, "User not found")
        user.session_version += 1
        db.commit()
        return {"access_token": make_token(user.id, user.session_version)}
