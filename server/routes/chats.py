from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, and_, desc, func
from server.db.session import SessionLocal
from server.models import Chat, ChatMember, Message, User
from server.auth import current_user
from server.routes.ws import broadcast_to_users

router = APIRouter()

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

def message_payload(msg: Message, sender: User | None = None):
    return {
        "id": msg.id,
        "chat_id": msg.chat_id,
        "sender_id": msg.sender_id,
        "sender": {
            "id": sender.id,
            "username": sender.username,
            "display_name": sender.display_name,
        } if sender else None,
        "text": msg.text,
        "created_at": msg.created_at.isoformat(),
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
                select(Message)
                .where(Message.chat_id == chat.id)
                .order_by(desc(Message.id))
                .limit(1)
            )
            result.append({
                "id": chat.id,
                "title": chat.title or (peer.display_name if peer else "LEDERG chat"),
                "is_group": chat.is_group,
                "peer": {
                    "id": peer.id,
                    "username": peer.username,
                    "display_name": peer.display_name,
                } if peer else None,
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

            # Reuse an existing 1:1 chat instead of creating duplicates.
            direct_chat = db.scalar(
                select(Chat.id)
                .join(ChatMember, ChatMember.chat_id == Chat.id)
                .where(Chat.is_group.is_(False), ChatMember.user_id == me["id"])
            )
            if direct_chat:
                member_ids = db.scalars(
                    select(ChatMember.user_id).where(ChatMember.chat_id == direct_chat)
                ).all()
                if set(member_ids) == {me["id"], data.user_id}:
                    return {"id": direct_chat, "title": target.display_name, "is_group": False, "existing": True}

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
                    "is_group": chat.is_group,
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
        senders = {
            u.id: u
            for u in db.scalars(select(User).where(User.id.in_(sender_ids))).all()
        }
        return [message_payload(m, senders.get(m.sender_id)) for m in rows]

@router.post("/chats/{chat_id}/messages")
async def send_message(chat_id: int, data: MessageIn, me=Depends(current_user)):
    text_value = data.text.strip()
    if not text_value:
        raise HTTPException(422, "Message cannot be empty")

    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")

        msg = Message(
            chat_id=chat_id,
            sender_id=me["id"],
            text=text_value,
            created_at=now(),
        )
        db.add(msg)
        db.commit()
        db.refresh(msg)

        sender = db.get(User, me["id"])
        member_ids = db.scalars(
            select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
        ).all()
        payload = message_payload(msg, sender)

    await broadcast_to_users(
        member_ids,
        {"type": "new_message", "message": payload},
    )
    return payload
