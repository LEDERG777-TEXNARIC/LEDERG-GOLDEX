from datetime import datetime, timezone
import re

import jwt
import pyotp
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from server.auth import bearer, create_session, hash_password, make_token, verify_password
from server.config import settings
from server.db.session import SessionLocal
from server.models import Session, User

router = APIRouter()
USERNAME = re.compile(r"^[a-zA-Z0-9_.-]{3,32}$")


class RegisterIn(BaseModel):
    username: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=8, max_length=128)
    display_name: str = Field(min_length=1, max_length=80)
    remember_device: bool = True


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=8, max_length=128)
    otp_code: str | None = Field(default=None, min_length=6, max_length=8)
    remember_device: bool = True


def normalize_username(raw: str) -> str:
    username = (raw or "").strip().lstrip("@").lower()
    if not USERNAME.fullmatch(username):
        raise HTTPException(
            422,
            "Никнейм: 3–32 символа, только латинские буквы, цифры, _, - и .",
        )
    return username


def normalize_display_name(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        raise HTTPException(422, "Имя не может быть пустым")
    if len(value) > 80:
        raise HTTPException(422, "Имя слишком длинное (максимум 80 символов)")
    return value


def detect_device(request: Request) -> str:
    ua = (request.headers.get("user-agent") or "").lower()
    browser = "Браузер"
    if "edg/" in ua or "edge/" in ua:
        browser = "Edge"
    elif "yabrowser" in ua:
        browser = "Яндекс Браузер"
    elif "firefox/" in ua:
        browser = "Firefox"
    elif "chrome/" in ua:
        browser = "Chrome"
    elif "safari/" in ua and "chrome/" not in ua:
        browser = "Safari"

    platform = "устройство"
    if "windows" in ua:
        platform = "Windows"
    elif "android" in ua:
        platform = "Android"
    elif "iphone" in ua or "ipad" in ua:
        platform = "iOS"
    elif "mac os" in ua or "macintosh" in ua:
        platform = "macOS"
    elif "linux" in ua:
        platform = "Linux"
    return f"LEDERG • {browser} • {platform}"


def user_payload(user: User):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "bio": user.bio or "",
        "avatar_url": f"/media/{user.avatar_path}" if user.avatar_path and user.avatar_public else None,
        "created_at": user.created_at.isoformat() if user.created_at else None,
    }


@router.post("/register")
def register(data: RegisterIn, request: Request):
    username = normalize_username(data.username)
    display_name = normalize_display_name(data.display_name)

    with SessionLocal() as db:
        if db.scalar(select(User.id).where(User.username == username)):
            raise HTTPException(409, "Такой никнейм уже занят")
        user = User(
            username=username,
            display_name=display_name,
            password_hash=hash_password(data.password),
        )
        db.add(user)
        try:
            db.commit()
            db.refresh(user)
        except IntegrityError:
            db.rollback()
            raise HTTPException(409, "Такой никнейм уже занят")

        user_id = user.id
        payload = user_payload(user)

    _, token = create_session(
        user_id,
        remembered=data.remember_device,
        device_name=detect_device(request),
    )
    return {
        "access_token": token,
        "user": payload,
        "remembered": data.remember_device,
    }


@router.post("/login")
def login(data: LoginIn, request: Request):
    username = normalize_username(data.username)

    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.username == username))
        if not user or not verify_password(data.password, user.password_hash):
            raise HTTPException(401, "Неверный никнейм или пароль")

        if user.two_factor_enabled:
            code = (data.otp_code or "").replace(" ", "")
            if not code:
                raise HTTPException(
                    401,
                    detail={
                        "requires_2fa": True,
                        "message": "Введите код из приложения-аутентификатора",
                    },
                )
            if not user.two_factor_secret or not pyotp.TOTP(user.two_factor_secret).verify(
                code, valid_window=1
            ):
                raise HTTPException(
                    401,
                    detail={
                        "requires_2fa": True,
                        "message": "Неверный код двухэтапной проверки",
                    },
                )

        user_id = user.id
        payload = user_payload(user)

    _, token = create_session(
        user_id,
        remembered=data.remember_device,
        device_name=detect_device(request),
    )
    return {
        "access_token": token,
        "user": payload,
        "remembered": data.remember_device,
    }


@router.post("/refresh")
def refresh(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
):
    if not credentials:
        raise HTTPException(401, "Нужна активная сессия")
    try:
        payload = jwt.decode(
            credentials.credentials,
            settings.secret_key,
            algorithms=["HS256"],
            options={"verify_exp": False},
        )
        user_id = int(payload["sub"])
        sid = payload.get("sid")
    except Exception:
        raise HTTPException(401, "Сессия недействительна")

    # Legacy JWTs created before server-side sessions had no sid.
    # Migrate an unexpired legacy token once, instead of throwing the user out.
    if not sid:
        exp = payload.get("exp")
        if not exp or float(exp) <= datetime.now(timezone.utc).timestamp():
            raise HTTPException(401, "Старая сессия истекла")
        with SessionLocal() as db:
            user = db.get(User, user_id)
            if not user or not user.is_active:
                raise HTTPException(401, "Пользователь недоступен")
        _, token = create_session(
            user_id,
            remembered=True,
            device_name=detect_device(request),
        )
        return {
            "access_token": token,
            "remembered": True,
            "device_name": detect_device(request),
            "migrated": True,
        }

    with SessionLocal() as db:
        session = db.get(Session, sid)
        user = db.get(User, user_id)
        if not session or session.revoked or session.user_id != user_id or not user or not user.is_active:
            raise HTTPException(401, "Сессия завершена")

        if not session.remembered:
            try:
                jwt.decode(credentials.credentials, settings.secret_key, algorithms=["HS256"])
            except Exception:
                raise HTTPException(401, "Сессия истекла")

        session.last_seen_at = datetime.now(timezone.utc)
        db.commit()
        ttl = settings.token_minutes if session.remembered else min(settings.token_minutes, 720)
        return {
            "access_token": make_token(user_id, sid, ttl),
            "remembered": bool(session.remembered),
            "device_name": session.device_name or "LEDERG device",
        }


@router.post("/logout")
def logout(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if not credentials:
        return {"ok": True}

    try:
        payload = jwt.decode(
            credentials.credentials,
            settings.secret_key,
            algorithms=["HS256"],
            options={"verify_exp": False},
        )
        sid = payload.get("sid")
    except Exception:
        sid = None

    if sid:
        with SessionLocal() as db:
            session = db.get(Session, sid)
            if session:
                session.revoked = True
                db.commit()
    return {"ok": True}
