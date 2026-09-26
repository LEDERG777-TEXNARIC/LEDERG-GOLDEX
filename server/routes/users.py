from pathlib import Path
from uuid import uuid4
from fastapi import APIRouter, Depends, Query, UploadFile, File, HTTPException
from pydantic import BaseModel, Field
from typing import Literal
from sqlalchemy import select, or_, and_
from fastapi.responses import FileResponse

from server.db.session import SessionLocal
from server.models import User, BlockedUser
from server.auth import current_user
from server.presence import is_online
from server.privacy import can_view

router = APIRouter()
USERNAME = r"^[a-zA-Z0-9_.-]+$"

class ProfileUpdate(BaseModel):
    username: str | None = Field(default=None, min_length=3, max_length=32, pattern=USERNAME)
    display_name: str | None = Field(default=None, min_length=1, max_length=80)
    bio: str | None = Field(default=None, max_length=160)
    online_visibility: Literal["everyone", "chats", "nobody"] | None = None
    avatar_visibility: Literal["everyone", "chats", "nobody"] | None = None
    search_visible: bool | None = None
    read_receipts: bool | None = None
    typing_visibility: bool | None = None

class CryptoKeyIn(BaseModel):
    public_key: str = Field(min_length=20, max_length=4096)

def public_user(db, user: User, viewer_id: int):
    online_allowed = can_view(db, viewer_id, user, user.online_visibility)
    avatar_allowed = can_view(db, viewer_id, user, user.avatar_visibility)
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "online": bool(is_online(user.id) and online_allowed),
        "has_avatar": bool(user.avatar_path and avatar_allowed),
        "avatar_url": f"/api/users/{user.id}/avatar" if user.avatar_path and avatar_allowed else None,
        "crypto_public_key": user.crypto_public_key,
    }

def data_dir():
    from server.config import settings
    return Path(settings.data_dir)

@router.get("/me")
def me(user=Depends(current_user)):
    with SessionLocal() as db:
        u = db.get(User, user["id"])
        return {
            **public_user(db, u, u.id),
            "online_visibility": u.online_visibility,
            "avatar_visibility": u.avatar_visibility,
            "search_visible": bool(u.search_visible),
            "read_receipts": bool(u.read_receipts),
            "typing_visibility": bool(u.typing_visibility),
            "created_at": u.created_at.isoformat() if u.created_at else None,
        }

@router.patch("/me")
async def update_me(data: ProfileUpdate, me=Depends(current_user)):
    visibility_changed = data.online_visibility is not None
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user:
            raise HTTPException(404, "User not found")
        if data.username is not None:
            username = data.username.strip().lower()
            if db.scalar(select(User.id).where(and_(User.username == username, User.id != user.id))):
                raise HTTPException(409, "Username already exists")
            user.username = username
        if data.display_name is not None:
            value = data.display_name.strip()
            if not value:
                raise HTTPException(422, "Display name is required")
            user.display_name = value
        if data.bio is not None:
            user.bio = data.bio.strip()[:160]
        if data.online_visibility is not None:
            user.online_visibility = data.online_visibility
        if data.avatar_visibility is not None:
            user.avatar_visibility = data.avatar_visibility
        if data.search_visible is not None:
            user.search_visible = data.search_visible
        if data.read_receipts is not None:
            user.read_receipts = data.read_receipts
        if data.typing_visibility is not None:
            user.typing_visibility = data.typing_visibility
        db.commit()
        db.refresh(user)
        result = {
            **public_user(db, user, user.id),
            "online_visibility": user.online_visibility,
            "avatar_visibility": user.avatar_visibility,
            "search_visible": bool(user.search_visible),
            "read_receipts": bool(user.read_receipts),
            "typing_visibility": bool(user.typing_visibility),
        }
    if visibility_changed:
        from server.routes.ws import notify_presence
        await notify_presence(me["id"], True)
    return result

@router.post("/me/crypto-key")
def update_crypto_key(data: CryptoKeyIn, me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user:
            raise HTTPException(404, "User not found")
        user.crypto_public_key = data.public_key
        db.commit()
        return {"ok": True}

@router.post("/me/avatar")
async def upload_avatar(file: UploadFile = File(...), me=Depends(current_user)):
    allowed = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}
    ext = allowed.get(file.content_type or "")
    if not ext:
        raise HTTPException(415, "Avatar must be JPEG, PNG, WEBP or GIF")
    raw = await file.read(5 * 1024 * 1024 + 1)
    if len(raw) > 5 * 1024 * 1024:
        raise HTTPException(413, "Avatar is too large; max 5 MB")
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user:
            raise HTTPException(404, "User not found")
        folder = data_dir() / "uploads" / "avatars" / str(user.id)
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{uuid4().hex}{ext}"
        path.write_bytes(raw)
        old = data_dir() / user.avatar_path if user.avatar_path else None
        user.avatar_path = str(path.relative_to(data_dir()))
        db.commit()
        if old and old.exists() and old.resolve() != path.resolve():
            old.unlink(missing_ok=True)
        return {"ok": True, "avatar_url": f"/api/users/{user.id}/avatar?t={uuid4().hex}"}

@router.delete("/me/avatar")
def delete_avatar(me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, me["id"])
        if not user:
            raise HTTPException(404, "User not found")
        old = data_dir() / user.avatar_path if user.avatar_path else None
        user.avatar_path = None
        db.commit()
        if old and old.exists():
            old.unlink(missing_ok=True)
        return {"ok": True}

@router.get("/blocked")
def blocked(me=Depends(current_user)):
    with SessionLocal() as db:
        rows = db.scalars(
            select(User).join(BlockedUser, BlockedUser.blocked_id == User.id)
            .where(BlockedUser.blocker_id == me["id"]).order_by(User.username)
        ).all()
        return [public_user(db, u, me["id"]) for u in rows]

@router.post("/{user_id}/block")
def block_user(user_id: int, me=Depends(current_user)):
    if user_id == me["id"]:
        raise HTTPException(400, "Cannot block yourself")
    with SessionLocal() as db:
        if not db.get(User, user_id):
            raise HTTPException(404, "User not found")
        exists = db.scalar(select(BlockedUser.id).where(and_(
            BlockedUser.blocker_id == me["id"], BlockedUser.blocked_id == user_id
        )))
        if not exists:
            db.add(BlockedUser(blocker_id=me["id"], blocked_id=user_id))
            db.commit()
        return {"ok": True}

@router.delete("/{user_id}/block")
def unblock_user(user_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        row = db.scalar(select(BlockedUser).where(and_(
            BlockedUser.blocker_id == me["id"], BlockedUser.blocked_id == user_id
        )))
        if row:
            db.delete(row)
            db.commit()
        return {"ok": True}

@router.get("/{user_id}")
def get_user(user_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, user_id)
        if not user or not user.is_active:
            raise HTTPException(404, "User not found")
        return public_user(db, user, me["id"])

@router.get("/{user_id}/avatar")
def get_avatar(user_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        user = db.get(User, user_id)
        if not user or not user.avatar_path:
            raise HTTPException(404, "Avatar not found")
        if not can_view(db, me["id"], user, user.avatar_visibility):
            raise HTTPException(403, "Avatar is private")
        root = data_dir().resolve()
        path = (root / user.avatar_path).resolve()
        if root not in path.parents or not path.is_file():
            raise HTTPException(404, "Avatar not found")
        return FileResponse(path, headers={"Cache-Control": "private, max-age=300"})

@router.get("/search")
def search(q: str = Query(min_length=1, max_length=64), me=Depends(current_user)):
    value = q.strip().lstrip("@").lower()
    if not value:
        return []
    needle = f"%{value}%"
    with SessionLocal() as db:
        blocked_ids = select(BlockedUser.blocked_id).where(BlockedUser.blocker_id == me["id"])
        blocker_ids = select(BlockedUser.blocker_id).where(BlockedUser.blocked_id == me["id"])
        rows = db.scalars(
            select(User).where(
                User.is_active.is_(True),
                User.search_visible.is_(True),
                User.id != me["id"],
                User.id.not_in(blocked_ids),
                User.id.not_in(blocker_ids),
                or_(User.username.ilike(needle), User.display_name.ilike(needle)),
            ).order_by(User.username).limit(30)
        ).all()
        return [public_user(db, u, me["id"]) for u in rows]
