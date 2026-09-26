from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, and_, desc
from server.db.session import SessionLocal
from server.models import Chat, ChatMember, Message, User
from server.auth import current_user

router = APIRouter()

def is_member(db, chat_id, user_id):
    return db.scalar(select(ChatMember.id).where(and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id))) is not None

class ChatCreate(BaseModel):
    user_id: int | None = None
    title: str | None = Field(default=None, max_length=120)

class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=4096)

@router.get("/chats")
def list_chats(me=Depends(current_user)):
    with SessionLocal() as db:
        chats = db.scalars(
            select(Chat).join(ChatMember, Chat.id == ChatMember.chat_id)
            .where(ChatMember.user_id == me["id"]).order_by(desc(Chat.id))
        ).all()
        return [{"id": c.id, "title": c.title, "is_group": c.is_group} for c in chats]

@router.post("/chats")
def create_chat(data: ChatCreate, me=Depends(current_user)):
    if data.user_id == me["id"]:
        raise HTTPException(400, "Cannot create chat with yourself")
    with SessionLocal() as db:
        chat = Chat(title=data.title, is_group=data.user_id is None)
        db.add(chat); db.flush()
        db.add(ChatMember(chat_id=chat.id, user_id=me["id"]))
        if data.user_id is not None:
            if not db.get(User, data.user_id):
                raise HTTPException(404, "User not found")
            db.add(ChatMember(chat_id=chat.id, user_id=data.user_id))
        db.commit(); db.refresh(chat)
        return {"id": chat.id, "title": chat.title, "is_group": chat.is_group}

@router.get("/chats/{chat_id}/messages")
def messages(chat_id: int, before: int | None = Query(default=None), limit: int = Query(default=50, le=100), me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        q = select(Message).where(Message.chat_id == chat_id).order_by(desc(Message.id)).limit(limit)
        if before:
            q = q.where(Message.id < before)
        rows = list(reversed(db.scalars(q).all()))
        return [{"id": m.id, "chat_id": m.chat_id, "sender_id": m.sender_id, "text": m.text, "created_at": m.created_at.isoformat()} for m in rows]

@router.post("/chats/{chat_id}/messages")
def send_message(chat_id: int, data: MessageIn, me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db, chat_id, me["id"]):
            raise HTTPException(403, "Not a chat member")
        msg = Message(chat_id=chat_id, sender_id=me["id"], text=data.text)
        db.add(msg); db.commit(); db.refresh(msg)
        return {"id": msg.id, "chat_id": chat_id, "sender_id": me["id"], "text": msg.text, "created_at": msg.created_at.isoformat()}
