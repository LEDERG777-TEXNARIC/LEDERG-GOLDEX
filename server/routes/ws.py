from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import jwt
from server.config import settings
from server.db.session import SessionLocal
from server.models import ChatMember, User
from sqlalchemy import select, and_

router = APIRouter()
connections: dict[int, set[WebSocket]] = {}

def user_is_online(user_id: int) -> bool:
    return bool(connections.get(int(user_id)))

def connected_ids() -> set[int]:
    return {uid for uid, sockets in connections.items() if sockets}

async def send_user(user_id: int, payload: dict):
    dead = []
    for ws in list(connections.get(int(user_id), set())):
        try:
            await ws.send_json(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        connections.get(int(user_id), set()).discard(ws)

async def broadcast_to_users(user_ids, payload: dict):
    for uid in {int(x) for x in user_ids}:
        await send_user(uid, payload)

def chat_member_ids(user_id: int):
    with SessionLocal() as db:
        return db.scalars(
            select(ChatMember.user_id)
            .join(User, User.id == ChatMember.user_id)
            .where(
                ChatMember.chat_id.in_(
                    select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
                ),
                User.is_active.is_(True),
            )
        ).all()

async def broadcast_presence(user_id: int):
    with SessionLocal() as db:
        user = db.get(User, user_id)
        if not user:
            return
        peers = chat_member_ids(user_id)
    visible = bool(user.presence_visible)
    await broadcast_to_users(
        peers,
        {
            "type": "presence",
            "user_id": int(user_id),
            "online": bool(visible and user_is_online(user_id)),
        },
    )

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
        sid = payload.get("sid")
        if sid:
            with SessionLocal() as db:
                row = db.get(__import__("server.models", fromlist=["Session"]).Session, sid)
                if not row or row.revoked or row.user_id != uid:
                    raise ValueError("revoked")
    except Exception:
        await ws.close(code=1008)
        return

    with SessionLocal() as db:
        user = db.get(User, uid)
        if not user or not user.is_active:
            await ws.close(code=1008)
            return
        presence_visible = bool(user.presence_visible)

    await ws.accept()
    was_offline = not user_is_online(uid)
    connections.setdefault(uid, set()).add(ws)

    try:
        await ws.send_json({"type": "ready", "user_id": uid})
        if was_offline and presence_visible:
            await broadcast_presence(uid)

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
    except Exception:
        pass
    finally:
        connections.get(uid, set()).discard(ws)
        if not connections.get(uid):
            connections.pop(uid, None)
            await broadcast_presence(uid)
