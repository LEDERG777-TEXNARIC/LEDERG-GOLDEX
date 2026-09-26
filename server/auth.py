from datetime import datetime, timedelta, timezone
import secrets
import jwt
from pwdlib import PasswordHash
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy import select
from server.config import settings
from server.db.session import SessionLocal
from server.models import User, Session

password_hash = PasswordHash.recommended()
bearer = HTTPBearer(auto_error=False)

def hash_password(value: str) -> str:
    return password_hash.hash(value)

def verify_password(value: str, hashed: str) -> bool:
    return password_hash.verify(value, hashed)

def make_token(user_id: int, session_id: str | None = None) -> str:
    sid = session_id or secrets.token_urlsafe(32)
    exp = datetime.now(timezone.utc) + timedelta(minutes=settings.token_minutes)
    return jwt.encode({"sub": str(user_id), "sid": sid, "exp": exp}, settings.secret_key, algorithm="HS256")

def create_session(user_id: int) -> tuple[str, str]:
    sid = secrets.token_urlsafe(32)
    with SessionLocal() as db:
        db.add(Session(id=sid, user_id=user_id, created_at=datetime.now(timezone.utc), last_seen_at=datetime.now(timezone.utc)))
        db.commit()
    return sid, make_token(user_id, sid)

def validate_session(user_id: int, session_id: str | None) -> bool:
    if not session_id:
        return True
    with SessionLocal() as db:
        s = db.get(Session, session_id)
        if not s or s.revoked or s.user_id != user_id:
            return False
        s.last_seen_at = datetime.now(timezone.utc)
        db.commit()
        return True

def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if not credentials:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authorization required")
    try:
        payload = jwt.decode(credentials.credentials, settings.secret_key, algorithms=["HS256"])
        uid = int(payload["sub"])
        sid = payload.get("sid")
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
    if not validate_session(uid, sid):
        raise HTTPException(status_code=401, detail="Session revoked")
    with SessionLocal() as db:
        user = db.get(User, uid)
        if not user or not user.is_active:
            raise HTTPException(status_code=401, detail="User unavailable")
        return {
            "id": user.id,
            "username": user.username,
            "display_name": user.display_name,
            "bio": user.bio or "",
            "avatar_path": user.avatar_path,
            "discoverable": user.discoverable,
            "presence_visible": user.presence_visible,
            "avatar_public": user.avatar_public,
            "read_receipts": user.read_receipts,
            "allow_messages": user.allow_messages,
            "session_id": sid,
        }
