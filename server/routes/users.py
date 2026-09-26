import re
import secrets
from pathlib import Path
from fastapi import APIRouter, Depends, Query, HTTPException, UploadFile, File, Form
from pydantic import BaseModel, Field
from sqlalchemy import select, or_, update
from server.config import settings
from server.db.session import SessionLocal
from server.models import User, Session
from server.auth import current_user, hash_password, verify_password
from server.routes.ws import user_is_online, broadcast_presence

router = APIRouter()
USERNAME = re.compile(r"^[a-zA-Z0-9_.-]{3,32}$")
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_AVATAR_BYTES = 5 * 1024 * 1024

def public_user(user: User, viewer_id: int | None = None):
    can_presence = bool(user.presence_visible) or user.id == viewer_id
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "avatar_url": f"/media/{user.avatar_path}" if user.avatar_path and user.avatar_public else None,
        "online": bool(can_presence and user_is_online(user.id)),
    }

def private_user(user: User):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "avatar_url": f"/media/{user.avatar_path}" if user.avatar_path else None,
        "discoverable": user.discoverable,
        "presence_visible": user.presence_visible,
        "avatar_public": user.avatar_public,
        "read_receipts": user.read_receipts,
        "allow_messages": user.allow_messages,
    }

def _image_ext(upload: UploadFile):
    return {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
    }.get(upload.content_type)

@router.get("/search")
def search(q: str = Query(min_length=1, max_length=64), me=Depends(current_user)):
    clean = q.strip().lower()
    needle = f"%{clean}%"
    with SessionLocal() as db:
        rows = db.scalars(
            select(User)
            .where(
                User.is_active.is_(True),
                User.discoverable.is_(True),
                User.id != me["id"],
                or_(User.username.ilike(needle), User.display_name.ilike(needle)),
            )
            .order_by(User.username)
            .limit(30)
        ).all()
        return [public_user(u, me["id"]) for u in rows]

@router.get("/me")
def me(user=Depends(current_user)):
    with SessionLocal() as db:
        obj = db.get(User, user["id"])
        if not obj:
            raise HTTPException(404, "User not found")
        return private_user(obj)

@router.get("/{user_id}")
def get_user(user_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        obj = db.get(User, user_id)
        if not obj or not obj.is_active:
            raise HTTPException(404, "User not found")
        return public_user(obj, me["id"])

@router.put("/me")
async def update_me(
    username: str | None = Form(default=None),
    display_name: str | None = Form(default=None),
    bio: str | None = Form(default=None),
    discoverable: bool | None = Form(default=None),
    presence_visible: bool | None = Form(default=None),
    avatar_public: bool | None = Form(default=None),
    read_receipts: bool | None = Form(default=None),
    allow_messages: bool | None = Form(default=None),
    remove_avatar: bool = Form(default=False),
    avatar: UploadFile | None = File(default=None),
    me=Depends(current_user),
):
    new_username = username.strip().lower() if username is not None else None
    if new_username is not None:
        if not USERNAME.fullmatch(new_username):
            raise HTTPException(422, "Username must be 3-32 chars: a-z, 0-9, _, ., -")
    if display_name is not None and not display_name.strip():
        raise HTTPException(422, "Display name cannot be empty")
    if bio is not None and len(bio) > 160:
        raise HTTPException(422, "Bio is too long")

    new_avatar_rel = None
    old_avatar_rel = None
    if remove_avatar and avatar is not None:
        raise HTTPException(400, "Choose remove avatar or upload a new avatar")

    if avatar is not None:
        ext = _image_ext(avatar)
        if not ext:
            raise HTTPException(415, "Use JPG, PNG or WEBP")
        data = await avatar.read(MAX_AVATAR_BYTES + 1)
        if len(data) > MAX_AVATAR_BYTES:
            raise HTTPException(413, "Avatar is too large (max 5 MB)")
        magic_ok = (
            (ext == "jpg" and data[:3] == b"\xff\xd8\xff")
            or (ext == "png" and data[:8] == b"\x89PNG\r\n\x1a\n")
            or (ext == "webp" and data[:4] == b"RIFF" and data[8:12] == b"WEBP")
        )
        if not magic_ok:
            raise HTTPException(415, "Invalid image file")
        folder = Path(settings.data_dir) / "uploads" / "avatars"
        folder.mkdir(parents=True, exist_ok=True)
        filename = f"{me['id']}_{secrets.token_hex(12)}.{ext}"
        path = folder / filename
        path.write_bytes(data)
        new_avatar_rel = f"uploads/avatars/{filename}"

    with SessionLocal() as db:
        obj = db.get(User, me["id"])
        if not obj:
            raise HTTPException(404, "User not found")
        if new_username and new_username != obj.username:
            if db.scalar(select(User.id).where(User.username == new_username, User.id != obj.id)):
                raise HTTPException(409, "Username already exists")
            obj.username = new_username
        if display_name is not None:
            obj.display_name = display_name.strip()
        if bio is not None:
            obj.bio = bio.strip()
        for field, value in (
            ("discoverable", discoverable),
            ("presence_visible", presence_visible),
            ("avatar_public", avatar_public),
            ("read_receipts", read_receipts),
            ("allow_messages", allow_messages),
        ):
            if value is not None:
                setattr(obj, field, value)
        if new_avatar_rel:
            old_avatar_rel = obj.avatar_path
            obj.avatar_path = new_avatar_rel
        elif remove_avatar:
            old_avatar_rel = obj.avatar_path
            obj.avatar_path = None
        db.commit()
        db.refresh(obj)
        result = private_user(obj)

    if old_avatar_rel:
        old = Path(settings.data_dir) / old_avatar_rel
        try:
            old.unlink(missing_ok=True)
        except OSError:
            pass
    await broadcast_presence(obj.id)
    return result

class PasswordIn(BaseModel):
    old_password: str = Field(min_length=8, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)

@router.post("/password")
def change_password(data: PasswordIn, me=Depends(current_user)):
    with SessionLocal() as db:
        obj = db.get(User, me["id"])
        if not obj or not verify_password(data.old_password, obj.password_hash):
            raise HTTPException(400, "Current password is incorrect")
        obj.password_hash = hash_password(data.new_password)
        db.execute(
            update(Session).where(Session.user_id == obj.id, Session.id != me["session_id"]).values(revoked=True)
        )
        db.commit()
    return {"ok": True, "message": "Password changed; other sessions were revoked"}

@router.get("/sessions/list")
def sessions(me=Depends(current_user)):
    with SessionLocal() as db:
        rows = db.scalars(
            select(Session).where(Session.user_id == me["id"]).order_by(Session.created_at.desc())
        ).all()
        return [
            {
                "id": s.id,
                "created_at": s.created_at.isoformat(),
                "last_seen_at": s.last_seen_at.isoformat(),
                "current": s.id == me["session_id"],
                "revoked": s.revoked,
            }
            for s in rows
        ]

@router.delete("/sessions/{session_id}")
def revoke_session(session_id: str, me=Depends(current_user)):
    with SessionLocal() as db:
        s = db.get(Session, session_id)
        if not s or s.user_id != me["id"]:
            raise HTTPException(404, "Session not found")
        s.revoked = True
        db.commit()
    return {"ok": True}

@router.post("/sessions/revoke-all")
def revoke_all_sessions(me=Depends(current_user)):
    with SessionLocal() as db:
        db.execute(update(Session).where(Session.user_id == me["id"]).values(revoked=True))
        db.commit()
    return {"ok": True}
