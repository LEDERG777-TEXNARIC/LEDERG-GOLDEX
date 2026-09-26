from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import jwt
from server.config import settings

router = APIRouter()
connections: dict[int, set[WebSocket]] = {}

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
        while True:
            data = await ws.receive_json()
            await ws.send_json({"type": "ack", "event": data.get("type")})
    except WebSocketDisconnect:
        connections.get(uid, set()).discard(ws)
