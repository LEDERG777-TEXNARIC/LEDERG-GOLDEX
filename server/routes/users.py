from fastapi import APIRouter, Depends, Query
from sqlalchemy import select, or_
from server.db.session import SessionLocal
from server.models import User
from server.auth import current_user

router = APIRouter()

def public_user(user: User):
    return {
        "id": user.id,
        "username": user.username,
        "display_name": user.display_name,
    }

@router.get("/search")
def search(q: str = Query(min_length=1, max_length=64), me=Depends(current_user)):
    needle = f"%{q.strip().lower()}%"
    if len(q.strip()) < 1:
        return []
    with SessionLocal() as db:
        rows = db.scalars(
            select(User)
            .where(
                User.is_active.is_(True),
                User.id != me["id"],
                or_(
                    User.username.ilike(needle),
                    User.display_name.ilike(needle),
                ),
            )
            .order_by(User.username)
            .limit(30)
        ).all()
        return [public_user(u) for u in rows]

@router.get("/me")
def me(user=Depends(current_user)):
    return user
