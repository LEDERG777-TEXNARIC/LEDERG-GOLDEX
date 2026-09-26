from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import jwt
from server.config import settings
from server.db.session import SessionLocal
from server.models import ChatMember
from sqlalchemy import select, and_

router = APIRouter()
connections: dict[int, set[WebSocket]] = {}

async def send_user(user_id: int, payload: dict):
    for ws in list(connections.get(user_id, set())):
        try:
            await ws.send_json(payload)
        except Exception:
            connections.get(user_id, set()).discard(ws)

async def broadcast_to_users(user_ids, payload: dict):
    targets = {int(uid) for uid in user_ids}
    for uid in targets:
        await send_user(uid, payload)

def user_is_member(user_id: int, chat_id: int) -> bool:
    with SessionLocal() as db:
        return db.scalar(
            select(ChatMember.id).where(
                and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
            )
        ) is not None

@router.websocket("/ws")
async def websocket(ws: WebSocket):
    token = ws.query_params.get("token")
    try:
        payload = jwt.decode(token or "", settings.secret_key, algorithms=["HS256"])
        uid = int(payload["sub"])
    except Exception:
        await ws.close(code=1008)
        return

    await ws.accept()
    connections.setdefault(uid, set()).add(ws)

    try:
        await ws.send_json({"type": "ready", "user_id": uid})
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
                    member_ids = db.scalars(
                        select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
                    ).all()

                event = {
                    "type": event_type,
                    "chat_id": chat_id,
                    "user_id": uid,
                }
                if event_type == "typing":
                    event["is_typing"] = bool(data.get("is_typing", False))
                if event_type == "read":
                    event["message_id"] = data.get("message_id")
                await broadcast_to_users(member_ids, event)

    except WebSocketDisconnect:
        pass
    finally:
        connections.get(uid, set()).discard(ws)
        if not connections.get(uid):
            connections.pop(uid, None)
