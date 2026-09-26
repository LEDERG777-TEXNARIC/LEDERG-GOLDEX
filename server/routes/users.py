import re
import secrets
from pathlib import Path
import pyotp
from fastapi import APIRouter, Depends, Query, HTTPException, UploadFile, File, Form
from pydantic import BaseModel, Field
from sqlalchemy import select, or_, update, and_
from server.config import settings
from server.db.session import SessionLocal
from server.models import User, Session, Block
from server.auth import current_user, hash_password, verify_password
from server.routes.ws import user_is_online, broadcast_presence

router = APIRouter()
USERNAME = re.compile(r"^[a-zA-Z0-9_.-]{3,32}$")
MAX_AVATAR_BYTES = 5 * 1024 * 1024

def is_blocked(db, blocker_id: int, blocked_id: int) -> bool:
    return db.scalar(
        select(Block.id).where(Block.blocker_id == blocker_id, Block.blocked_id == blocked_id)
    ) is not None

def blocked_either_way(db, a: int, b: int) -> bool:
    return db.scalar(
        select(Block.id).where(
            or_(
                and_(Block.blocker_id == a, Block.blocked_id == b),
                and_(Block.blocker_id == b, Block.blocked_id == a),
            )
        )
    ) is not None

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
        "two_factor_enabled": user.two_factor_enabled,
    }

def _image_ext(upload: UploadFile):
    return {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}.get(upload.content_type)

@router.get("/search")
def search(q: str = Query(min_length=1, max_length=64), me=Depends(current_user)):
    clean = q.strip().lstrip("@").lower()
    needle = f"%{clean}%"
    with SessionLocal() as db:
        blocked_ids = set(db.scalars(
            select(Block.blocked_id).where(Block.blocker_id == me["id"])
        ).all())
        blocking_ids = set(db.scalars(
            select(Block.blocker_id).where(Block.blocked_id == me["id"])
        ).all())
        excluded = blocked_ids | blocking_ids | {me["id"]}
        rows = db.scalars(
            select(User).where(
                User.is_active.is_(True),
                User.discoverable.is_(True),
                User.id.not_in(excluded) if excluded else True,
                or_(User.username.ilike(needle), User.display_name.ilike(needle)),
            ).order_by(User.username).limit(30)
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
        if not obj or not obj.is_active or blocked_either_way(db, me["id"], user_id):
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
    if new_username is not None and not USERNAME.fullmatch(new_username):
        raise HTTPException(422, "Username must be 3-32 chars: a-z, 0-9, _, - or .")
    if display_name is not None and not display_name.strip():
        raise HTTPException(422, "Display name cannot be empty")
    if bio is not None and len(bio) > 160:
        raise HTTPException(422, "Bio is too long")
    if remove_avatar and avatar is not None:
        raise HTTPException(400, "Choose remove avatar or upload a new avatar")

    new_avatar_rel = None
    old_avatar_rel = None
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
        (folder / filename).write_bytes(data)
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
        try:
            (Path(settings.data_dir) / old_avatar_rel).unlink(missing_ok=True)
        except OSError:
            pass
    await broadcast_presence(me["id"])
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
        db.execute(update(Session).where(Session.user_id == obj.id, Session.id != me["session_id"]).values(revoked=True))
        db.commit()
    return {"ok": True, "message": "Password changed; other sessions were revoked"}

class BlockIn(BaseModel):
    user_id: int

@router.get("/blocks")
def list_blocks(me=Depends(current_user)):
    with SessionLocal() as db:
        ids = db.scalars(select(Block.blocked_id).where(Block.blocker_id == me["id"]).order_by(Block.id.desc())).all()
        users = {u.id:u for u in db.scalars(select(User).where(User.id.in_(ids))).all()} if ids else {}
        return [public_user(users[i], me["id"]) for i in ids if i in users]

@router.post("/blocks")
def block_user(data: BlockIn, me=Depends(current_user)):
    if data.user_id == me["id"]:
        raise HTTPException(400, "Cannot block yourself")
    with SessionLocal() as db:
        target=db.get(User,data.user_id)
        if not target or not target.is_active:
            raise HTTPException(404,"User not found")
        if not is_blocked(db,me["id"],data.user_id):
            db.add(Block(blocker_id=me["id"],blocked_id=data.user_id))
            db.commit()
    return {"ok":True}

@router.delete("/blocks/{user_id}")
def unblock_user(user_id:int, me=Depends(current_user)):
    with SessionLocal() as db:
        db.query(Block).filter(Block.blocker_id==me["id"],Block.blocked_id==user_id).delete(synchronize_session=False)
        db.commit()
    return {"ok":True}

class TwoFASetupIn(BaseModel):
    password: str = Field(min_length=8, max_length=128)

class TwoFAConfirmIn(BaseModel):
    code: str = Field(min_length=6, max_length=8)

@router.post("/2fa/setup")
def two_fa_setup(data: TwoFASetupIn, me=Depends(current_user)):
    with SessionLocal() as db:
        user=db.get(User,me["id"])
        if not user or not verify_password(data.password,user.password_hash):
            raise HTTPException(400,"Password is incorrect")
        if user.two_factor_enabled:
            raise HTTPException(400,"Two-factor authentication is already enabled")
        secret=pyotp.random_base32()
        user.two_factor_secret=secret
        db.commit()
        uri=pyotp.TOTP(secret).provisioning_uri(name=user.username, issuer_name="LEDERG")
        return {"secret":secret,"otpauth_uri":uri}

@router.post("/2fa/confirm")
def two_fa_confirm(data: TwoFAConfirmIn, me=Depends(current_user)):
    with SessionLocal() as db:
        user=db.get(User,me["id"])
        if not user or not user.two_factor_secret:
            raise HTTPException(400,"Start 2FA setup first")
        if not pyotp.TOTP(user.two_factor_secret).verify(data.code.replace(" ",""), valid_window=1):
            raise HTTPException(400,"Invalid authenticator code")
        user.two_factor_enabled=True
        db.commit()
        return {"ok":True}

@router.post("/2fa/disable")
def two_fa_disable(data: TwoFASetupIn, code: str = Query(min_length=6, max_length=8), me=Depends(current_user)):
    with SessionLocal() as db:
        user=db.get(User,me["id"])
        if not user or not verify_password(data.password,user.password_hash):
            raise HTTPException(400,"Password is incorrect")
        if not user.two_factor_enabled or not user.two_factor_secret:
            raise HTTPException(400,"Two-factor authentication is not enabled")
        if not pyotp.TOTP(user.two_factor_secret).verify(code.replace(" ",""), valid_window=1):
            raise HTTPException(400,"Invalid authenticator code")
        user.two_factor_enabled=False
        user.two_factor_secret=None
        db.commit()
    return {"ok":True}

@router.get("/sessions/list")
def sessions(me=Depends(current_user)):
    with SessionLocal() as db:
        rows=db.scalars(select(Session).where(Session.user_id==me["id"]).order_by(Session.created_at.desc())).all()
        return [{
            "id":s.id,"created_at":s.created_at.isoformat(),"last_seen_at":s.last_seen_at.isoformat(),
            "current":s.id==me["session_id"],"revoked":s.revoked
        } for s in rows]

@router.delete("/sessions/{session_id}")
def revoke_session(session_id:str, me=Depends(current_user)):
    with SessionLocal() as db:
        s=db.get(Session,session_id)
        if not s or s.user_id!=me["id"]:
            raise HTTPException(404,"Session not found")
        s.revoked=True
        db.commit()
    return {"ok":True}

@router.post("/sessions/revoke-all")
def revoke_all_sessions(me=Depends(current_user)):
    with SessionLocal() as db:
        db.execute(update(Session).where(Session.user_id==me["id"]).values(revoked=True))
        db.commit()
    return {"ok":True}
