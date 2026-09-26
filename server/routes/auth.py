from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from server.db.session import SessionLocal
from server.models import User
from server.auth import hash_password, verify_password, create_session

router = APIRouter()
USERNAME = r"^[a-zA-Z0-9_.-]+$"

class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=USERNAME)
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=1, max_length=80)

class LoginIn(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=USERNAME)
    password: str = Field(min_length=8, max_length=128)

def user_payload(user: User):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "avatar_url": f"/media/{user.avatar_path}" if user.avatar_path and user.avatar_public else None,
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
        user = User(
            username=username,
            display_name=display_name,
            password_hash=hash_password(data.password),
        )
        db.add(user)
        db.commit()
        db.refresh(user)
        user_id = user.id

    _, token = create_session(user_id)
    return {"access_token": token, "user": user_payload(user)}

@router.post("/login")
def login(data: LoginIn):
    username = data.username.strip().lower()
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.username == username))
        if not user or not verify_password(data.password, user.password_hash):
            raise HTTPException(401, "Invalid username or password")
        user_id = user.id
        payload = user_payload(user)

    _, token = create_session(user_id)
    return {"access_token": token, "user": payload}
