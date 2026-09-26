from fastapi import APIRouter, Depends
from server.auth import current_user
from server.db.session import SessionLocal
from server.models import Block
from sqlalchemy import select, or_, and_
from server.config import settings

router = APIRouter()

@router.get("/config")
def calls_config(me=Depends(current_user)):
    ice_servers = []
    if settings.stun_url:
        ice_servers.append({"urls": settings.stun_url})
    if settings.turn_url and settings.turn_username and settings.turn_credential:
        ice_servers.append({
            "urls": settings.turn_url,
            "username": settings.turn_username,
            "credential": settings.turn_credential,
        })
    return {
        "ice_servers": ice_servers,
        "relay_available": bool(settings.turn_url and settings.turn_username and settings.turn_credential),
    }
