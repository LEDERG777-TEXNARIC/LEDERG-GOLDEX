from datetime import datetime, timezone
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import jwt
from sqlalchemy import select, and_

from server.config import settings
from server.db.session import SessionLocal
from server.models import ChatMember, User
from server.presence import mark_online, mark_offline
from server.privacy import can_view

router = APIRouter()
connections: dict[int, set[WebSocket]] = {}

async def send_user(user_id: int, payload: dict):
    for ws in list(connections.get(user_id, set())):
        try:
            await ws.send_json(payload)
        except Exception:
            connections.get(user_id, set()).discard(ws)

async def broadcast_to_users(user_ids, payload: dict):
    for uid in {int(x) for x in user_ids}:
        await send_user(uid, payload)

def user_is_member(user_id: int, chat_id: int) -> bool:
    with SessionLocal() as db:
        return db.scalar(
            select(ChatMember.id).where(
                and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
            )
        ) is not None

def member_ids_for_user(db, user_id: int) -> list[int]:
    chat_ids = select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
    return db.scalars(
        select(ChatMember.user_id)
        .where(ChatMember.chat_id.in_(chat_ids))
        .distinct()
    ).all()

async def notify_presence(user_id: int, online: bool):
    with SessionLocal() as db:
        user = db.get(User, user_id)
        if not user:
            return
        recipients = member_ids_for_user(db, user_id)
        if online:
        visible = [
            uid for uid in recipients
            if uid != user_id and can_view(db, uid, user, user.online_visibility)
        ]
    else:
        visible = [uid for uid in recipients if uid != user_id]
    await broadcast_to_users(
        visible,
        {"type": "presence", "user_id": user_id, "online": online},
    )

@router.websocket("/ws")
async def websocket(ws: WebSocket):
    token = ws.query_params.get("token")
    try:
        payload = jwt.decode(token or "", settings.secret_key, algorithms=["HS256"])
        uid = int(payload["sub"])
        sv = int(payload.get("sv", 0))
    except Exception:
        await ws.close(code=1008)
        return

    with SessionLocal() as db:
        user = db.get(User, uid)
        if not user or not user.is_active or user.session_version != sv:
            await ws.close(code=1008)
            return

    await ws.accept()
    was_offline = uid not in connections or not connections[uid]
    connections.setdefault(uid, set()).add(ws)
    if was_offline:
        mark_online(uid)
        await notify_presence(uid, True)

    try:
        await ws.send_json({"type": "ready", "user_id": uid, "online": True})
        while True:
            data = await ws.receive_json()
            event_type = data.get("type")

            if event_type == "ping":
                await ws.send_json({"type": "pong"})
                continue

            if event_type in {"typing", "read"}:
                try:
                    chat_id = int(data.get("chat_id"))
                except (TypeError, ValueError):
                    continue
                if not user_is_member(uid, chat_id):
                    continue

                with SessionLocal() as db:
                    sender = db.get(User, uid)
                    if not sender:
                        continue
                    if event_type == "typing" and not sender.typing_visibility:
                        continue
                    if event_type == "read" and not sender.read_receipts:
                        continue
                    member_ids = db.scalars(
                        select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
                    ).all()

                event = {"type": event_type, "chat_id": chat_id, "user_id": uid}
                if event_type == "typing":
                    event["is_typing"] = bool(data.get("is_typing", False))
                else:
                    event["message_id"] = data.get("message_id")
                await broadcast_to_users(member_ids, event)

    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        connections.get(uid, set()).discard(ws)
        if not connections.get(uid):
            connections.pop(uid, None)
            mark_offline(uid)
            with SessionLocal() as db:
                user = db.get(User, uid)
                if user:
                    user.last_seen_at = datetime.now(timezone.utc)
                    db.commit()
            await notify_presence(uid, False)
