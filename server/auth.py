from datetime import datetime, timedelta, timezone
import jwt
from pwdlib import PasswordHash
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from server.config import settings
from server.db.session import SessionLocal
from server.models import User

password_hash = PasswordHash.recommended()
bearer = HTTPBearer(auto_error=False)

def hash_password(value: str) -> str:
    return password_hash.hash(value)

def verify_password(value: str, hashed: str) -> bool:
    return password_hash.verify(value, hashed)

def make_token(user_id: int, session_version: int = 0) -> str:
    exp = datetime.now(timezone.utc) + timedelta(minutes=settings.token_minutes)
    return jwt.encode(
        {"sub": str(user_id), "sv": int(session_version), "exp": exp},
        settings.secret_key,
        algorithm="HS256",
    )

def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if not credentials:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authorization required")
    try:
        payload = jwt.decode(credentials.credentials, settings.secret_key, algorithms=["HS256"])
        uid = int(payload["sub"])
        sv = int(payload.get("sv", 0))
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token")
    with SessionLocal() as db:
        user = db.get(User, uid)
        if not user or not user.is_active:
            raise HTTPException(status_code=401, detail="User unavailable")
        if user.session_version != sv:
            raise HTTPException(status_code=401, detail="Session revoked")
        return {"id": user.id, "username": user.username, "display_name": user.display_name}
