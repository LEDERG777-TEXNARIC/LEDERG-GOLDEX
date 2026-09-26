from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, or_
from server.db.session import SessionLocal
from server.models import User
from server.auth import current_user

router = APIRouter()

@router.get("/search")
def search(q: str = Query(min_length=1, max_length=64), me=Depends(current_user)):
    needle = f"%{q.lower()}%"
    with SessionLocal() as db:
        rows = db.scalars(
            select(User).where(
                User.is_active == True,
                User.id != me["id"],
                or_(User.username.ilike(needle), User.display_name.ilike(needle))
            ).limit(30)
        ).all()
        return [{"id": u.id, "username": u.username, "display_name": u.display_name} for u in rows]

@router.get("/me")
def me(user=Depends(current_user)):
    return user
