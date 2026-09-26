from datetime import datetime, timedelta, timezone
import secrets
import jwt
from pwdlib import PasswordHash
from fastapi import Depends, HTTPException, Request, status
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

def make_token(user_id: int, session_id: str | None = None, minutes: int | None = None) -> str:
    sid = session_id or secrets.token_urlsafe(32)
    ttl = minutes if minutes is not None else settings.token_minutes
    exp = datetime.now(timezone.utc) + timedelta(minutes=ttl)
    return jwt.encode({"sub": str(user_id), "sid": sid, "exp": exp}, settings.secret_key, algorithm="HS256")

def create_session(
    user_id: int,
    remembered: bool = True,
    device_name: str = "LEDERG device",
) -> tuple[str, str]:
    sid = secrets.token_urlsafe(32)
    now = datetime.now(timezone.utc)
    ttl = settings.token_minutes if remembered else min(settings.token_minutes, 720)
    with SessionLocal() as db:
        db.add(Session(
            id=sid,
            user_id=user_id,
            created_at=now,
            last_seen_at=now,
            device_name=(device_name or "LEDERG device")[:120],
            remembered=remembered,
        ))
        db.commit()
    return sid, make_token(user_id, sid, ttl)

def validate_session(user_id: int, session_id: str | None) -> bool:
    if not session_id:
        return False
    with SessionLocal() as db:
        s = db.get(Session, session_id)
        if not s or s.revoked or s.user_id != user_id:
            return False
        now = datetime.now(timezone.utc)
        # SQLite returns DateTime(timezone=True) values as naive datetimes.
        # Normalize persisted timestamps to UTC before comparing them.
        last_seen = s.last_seen_at
        if last_seen is not None:
            if last_seen.tzinfo is None:
                last_seen = last_seen.replace(tzinfo=timezone.utc)
            else:
                last_seen = last_seen.astimezone(timezone.utc)

        # Do not write SQLite on every API request; update the device heartbeat at most once/minute.
        if not last_seen or (now - last_seen).total_seconds() >= 60:
            try:
                s.last_seen_at = now
                db.commit()
            except Exception:
                db.rollback()
        return True


def _auth_candidates(request: Request, credentials: HTTPAuthorizationCredentials | None):
    candidates = []
    for source, raw in (
        ("bearer", credentials.credentials if credentials else None),
        ("cookie", request.cookies.get("lederg_auth")),
    ):
        if raw and not any(existing == raw for _, existing in candidates):
            candidates.append((source, raw))
    return candidates


def _decode_session_token(raw: str) -> dict:
    return jwt.decode(
        raw,
        settings.secret_key,
        algorithms=["HS256"],
        options={"verify_exp": False},
    )


def current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
):
    if not credentials:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authorization required")
    if not credentials and not request.cookies.get("lederg_auth"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authorization required")
    last_error = "Authorization required"
    for source, raw in _auth_candidates(request, credentials):
        try:
            payload = _decode_session_token(raw)
            uid = int(payload["sub"])
            sid = payload.get("sid")
            if not sid:
                last_error = "Invalid token"
                continue
            if not validate_session(uid, sid):
                last_error = "Session revoked"
                continue
            with SessionLocal() as db:
                user = db.get(User, uid)
                if not user or not user.is_active:
                    last_error = "User unavailable"
                    continue
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
        except Exception as exc:
            last_error = f"{source}: invalid session"
            print(f"[AUTH] current_user rejected {source}: {type(exc).__name__}")
    raise HTTPException(status_code=401, detail=last_error)
