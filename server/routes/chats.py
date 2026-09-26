from datetime import datetime, timezone
from pathlib import Path
import secrets
from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, File
from pydantic import BaseModel, Field
from sqlalchemy import select, and_, desc, or_
from server.config import settings
from server.db.session import SessionLocal
from server.models import Chat, ChatMember, ChatPreference, Message, User, Block
from server.auth import current_user
from server.routes.ws import broadcast_to_users, user_is_online

router = APIRouter()
ALLOWED_WALLPAPER_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_WALLPAPER_BYTES = 12 * 1024 * 1024

def now():
    return datetime.now(timezone.utc)

def is_member(db, chat_id: int, user_id: int) -> bool:
    return db.scalar(
        select(ChatMember.id).where(
            and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
        )
    ) is not None

def chat_users(db, chat_id: int):
    return db.scalars(
        select(User)
        .join(ChatMember, ChatMember.user_id == User.id)
        .where(ChatMember.chat_id == chat_id)
        .order_by(User.id)
    ).all()

def peer_payload(user: User, viewer_id: int):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "avatar_url": f"/media/{user.avatar_path}" if user.avatar_path and user.avatar_public else None,
        "online": bool(user.presence_visible and user_is_online(user.id)),
    }

def message_payload(msg: Message, sender: User | None = None):
    return {
        "id": msg.id,
        "chat_id": msg.chat_id,
        "sender_id": msg.sender_id,
        "sender": {
            "id": sender.id,
            "username": sender.username,
            "display_name": sender.display_name,
            "avatar_url": f"/media/{sender.avatar_path}" if sender and sender.avatar_path and sender.avatar_public else None,
            "online": bool(sender and sender.presence_visible and user_is_online(sender.id)),
        } if sender else None,
        "text": msg.text,
        "created_at": msg.created_at.isoformat(),
        "edited_at": msg.edited_at.isoformat() if msg.edited_at else None,
    }

class ChatCreate(BaseModel):
    user_id: int | None = None
    title: str | None = Field(default=None, max_length=120)

class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=4096)

@router.get("/chats")
def list_chats(me=Depends(current_user)):
    with SessionLocal() as db:
        chats = db.scalars(
            select(Chat)
            .join(ChatMember, Chat.id == ChatMember.chat_id)
            .where(ChatMember.user_id == me["id"])
            .order_by(desc(Chat.id))
        ).all()

        result = []
        for chat in chats:
            members = chat_users(db, chat.id)
            peer = next((u for u in members if u.id != me["id"]), None)
            last = db.scalar(
                select(Message).where(Message.chat_id == chat.id).order_by(desc(Message.id)).limit(1)
            )
            result.append({
                "id": chat.id,
                "title": chat.title or (peer.display_name if peer else "LEDERG chat"),
                "is_group": bool(chat.is_group),
                "peer": peer_payload(peer, me["id"]) if peer and not chat.is_group else None,
                "last_message": {
                    "id": last.id,
                    "sender_id": last.sender_id,
                    "text": last.text,
                    "created_at": last.created_at.isoformat(),
                } if last else None,
            })
        return result

@router.post("/chats")
async def create_chat(data: ChatCreate, me=Depends(current_user)):
    if data.user_id is None and not (data.title and data.title.strip()):
        raise HTTPException(422, "Group title is required")
    if data.user_id == me["id"]:
        raise HTTPException(400, "Cannot create chat with yourself")

    with SessionLocal() as db:
        if data.user_id is not None:
            target = db.get(User, data.user_id)
            if not target or not target.is_active:
                raise HTTPException(404, "User not found")
            if not target.allow_messages:
                raise HTTPException(403, "This user does not accept new messages")
            blocked = db.scalar(
                select(Block.id).where(
                    or_(
                        and_(Block.blocker_id == me["id"], Block.blocked_id == data.user_id),
                        and_(Block.blocker_id == data.user_id, Block.blocked_id == me["id"]),
                    )
                )
            )
            if blocked:
                raise HTTPException(403, "Messaging is unavailable for this user")

            direct_chats = db.scalars(
                select(Chat)
                .join(ChatMember, ChatMember.chat_id == Chat.id)
                .where(Chat.is_group.is_(False), ChatMember.user_id == me["id"])
            ).all()
            for direct_chat in direct_chats:
                member_ids = db.scalars(
                    select(ChatMember.user_id).where(ChatMember.chat_id == direct_chat.id)
                ).all()
                if set(member_ids) == {me["id"], data.user_id}:
                    return {
                        "id": direct_chat.id,
                        "title": target.display_name,
                        "is_group": False,
                        "existing": True,
                    }

        chat = Chat(
            title=data.title.strip() if data.title else None,
            is_group=data.user_id is None,
            created_at=now(),
        )
        db.add(chat)
        db.flush()
        db.add(ChatMember(chat_id=chat.id, user_id=me["id"]))
        if data.user_id is not None:
            db.add(ChatMember(chat_id=chat.id, user_id=data.user_id))
        db.commit()
        db.refresh(chat)

        if data.user_id is not None:
            await broadcast_to_users(
                [me["id"], data.user_id],
                {"type": "chat_created", "chat": {
                    "id": chat.id,
                    "title": data.title,
                    "is_group": False,
                }},
            )
        return {"id": chat.id, "title": chat.title, "is_group": chat.is_group}

@router.get("/chats/{chat_id}/messages")
def messages(
    chat_id: int,
    before: int | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    me=Depends(current_user),
):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        q = select(Message).where(Message.chat_id == chat_id).order_by(desc(Message.id)).limit(limit)
        if before:
            q = q.where(Message.id < before)
        rows = list(reversed(db.scalars(q).all()))
        if not rows:
            return []
        sender_ids = {m.sender_id for m in rows}
        senders = {u.id: u for u in db.scalars(select(User).where(User.id.in_(sender_ids))).all()}
        return [message_payload(m, senders.get(m.sender_id)) for m in rows]

@router.post("/chats/{chat_id}/messages")
async def send_message(chat_id: int, data: MessageIn, me=Depends(current_user)):
    text_value = data.text.strip()
    if not text_value:
        raise HTTPException(422, "Message cannot be empty")

    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")

        member_ids = db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)).all()
        if len(member_ids) == 2:
            other_id = next((uid for uid in member_ids if uid != me["id"]), None)
            if other_id is not None:
                blocked = db.scalar(select(Block.id).where(or_(
                    and_(Block.blocker_id == me["id"], Block.blocked_id == other_id),
                    and_(Block.blocker_id == other_id, Block.blocked_id == me["id"]),
                )))
                if blocked:
                    raise HTTPException(403, "Messaging is blocked")

        msg = Message(chat_id=chat_id, sender_id=me["id"], text=text_value, created_at=now())
        db.add(msg)
        db.commit()
        db.refresh(msg)

        sender = db.get(User, me["id"])
        payload = message_payload(msg, sender)

    await broadcast_to_users(member_ids, {"type": "new_message", "message": payload})
    return payload

def _wallpaper_ext(upload: UploadFile):
    return {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
    }.get(upload.content_type)

@router.get("/chats/{chat_id}/settings")
def chat_settings(chat_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        pref = db.scalar(select(ChatPreference).where(
            ChatPreference.chat_id == chat_id, ChatPreference.user_id == me["id"]
        ))
        return {
            "chat_id": chat_id,
            "wallpaper_url": f"/media/{pref.wallpaper_path}" if pref and pref.wallpaper_path else None,
            "muted": bool(pref.muted) if pref else False,
        }

@router.post("/chats/{chat_id}/wallpaper")
async def set_wallpaper(chat_id: int, wallpaper: UploadFile = File(...), me=Depends(current_user)):
    ext = _wallpaper_ext(wallpaper)
    if not ext:
        raise HTTPException(415, "Use JPG, PNG or WEBP")
    data = await wallpaper.read(MAX_WALLPAPER_BYTES + 1)
    if len(data) > MAX_WALLPAPER_BYTES:
        raise HTTPException(413, "Wallpaper is too large (max 12 MB)")
    magic_ok = (
        (ext == "jpg" and data[:3] == b"\xff\xd8\xff")
        or (ext == "png" and data[:8] == b"\x89PNG\r\n\x1a\n")
        or (ext == "webp" and data[:4] == b"RIFF" and data[8:12] == b"WEBP")
    )
    if not magic_ok:
        raise HTTPException(415, "Invalid image file")

    old_rel = None
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")

        folder = Path(settings.data_dir) / "uploads" / "wallpapers"
        folder.mkdir(parents=True, exist_ok=True)
        filename = f"chat_{chat_id}_{me['id']}_{secrets.token_hex(12)}.{ext}"
        path = folder / filename
        path.write_bytes(data)
        rel = f"uploads/wallpapers/{filename}"

        pref = db.scalar(select(ChatPreference).where(
            ChatPreference.chat_id == chat_id, ChatPreference.user_id == me["id"]
        ))
        if not pref:
            pref = ChatPreference(chat_id=chat_id, user_id=me["id"])
            db.add(pref)
        old_rel = pref.wallpaper_path
        pref.wallpaper_path = rel
        db.commit()

    if old_rel:
        try:
            (Path(settings.data_dir) / old_rel).unlink(missing_ok=True)
        except OSError:
            pass
    return {"ok": True, "wallpaper_url": f"/media/{rel}"}


@router.get("/chats/{chat_id}/call-permission")
def call_permission(chat_id: int, me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        members = db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)).all()
        other_id = next((uid for uid in members if uid != me["id"]), None)
        if other_id is None:
            raise HTTPException(400, "Call is only available in a private chat")
        peer = db.get(User, other_id)
        if not peer or not peer.allow_calls:
            return {"allowed": False, "reason": "The user does not accept calls"}
        blocked = db.scalar(select(Block.id).where(or_(
            and_(Block.blocker_id == me["id"], Block.blocked_id == other_id),
            and_(Block.blocker_id == other_id, Block.blocked_id == me["id"]),
        )))
        if blocked:
            return {"allowed": False, "reason": "Messaging and calls are blocked"}
        return {"allowed": True, "user_id": other_id}

@router.post("/chats/{chat_id}/mute")
def set_mute(chat_id: int, muted: bool = Query(...), me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        pref = db.scalar(select(ChatPreference).where(
            ChatPreference.chat_id == chat_id, ChatPreference.user_id == me["id"]
        ))
        if not pref:
            pref = ChatPreference(chat_id=chat_id, user_id=me["id"])
            db.add(pref)
        pref.muted = muted
        db.commit()
    return {"ok": True, "muted": muted}

@router.delete("/chats/{chat_id}/wallpaper")
def clear_wallpaper(chat_id: int, me=Depends(current_user)):
    old_rel = None
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        pref = db.scalar(select(ChatPreference).where(
            ChatPreference.chat_id == chat_id, ChatPreference.user_id == me["id"]
        ))
        if pref:
            old_rel = pref.wallpaper_path
            pref.wallpaper_path = None
            db.commit()
    if old_rel:
        try:
            (Path(settings.data_dir) / old_rel).unlink(missing_ok=True)
        except OSError:
            pass
    return {"ok": True, "wallpaper_url": None}
