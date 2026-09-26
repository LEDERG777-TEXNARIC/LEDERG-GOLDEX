from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import jwt
from server.config import settings
from server.db.session import SessionLocal
from server.models import ChatMember, User, Session, Block
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

async def relay_call_event(uid: int, data: dict):
    try:
        chat_id = int(data.get("chat_id"))
    except (TypeError, ValueError):
        return

    with SessionLocal() as db:
        member_ids = db.scalars(
            select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)
        ).all()
        if uid not in member_ids or len(member_ids) < 2:
            return
        peer_ids = [int(x) for x in member_ids if int(x) != int(uid)]
        peers = db.scalars(select(User).where(User.id.in_(peer_ids), User.is_active.is_(True))).all()
        if not any(bool(p.allow_calls) for p in peers):
            return
        blocked = db.scalar(select(Block.id).where(
            ((Block.blocker_id == uid) & (Block.blocked_id.in_(peer_ids))) |
            ((Block.blocker_id.in_(peer_ids)) & (Block.blocked_id == uid))
        ))
        if blocked:
            return

    call_type = data.get("type")
    if call_type not in {"call_invite","call_offer","call_answer","call_ice","call_end","call_reject"}:
        return
    event = {
        "type": call_type,
        "chat_id": chat_id,
        "from_user_id": uid,
    }
    for key in ("call_id","mode","description","candidate","reason"):
        if key in data:
            event[key] = data[key]
    await broadcast_to_users(peer_ids, event)


def chat_member_ids(user_id: int):
    with SessionLocal() as db:
        chat_ids = db.scalars(
            select(ChatMember.chat_id).where(ChatMember.user_id == user_id)
        ).all()
        if not chat_ids:
            return []
        return db.scalars(
            select(ChatMember.user_id)
            .join(User, User.id == ChatMember.user_id)
            .where(ChatMember.chat_id.in_(chat_ids), User.is_active.is_(True))
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
                row = db.get(Session, sid)
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

            if event_type in {"call_invite","call_offer","call_answer","call_ice","call_end","call_reject"}:
                await relay_call_event(uid, data)
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
