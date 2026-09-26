from sqlalchemy import and_, select
from server.models import ChatMember, User

def shares_chat(db, a_id: int, b_id: int) -> bool:
    return db.scalar(
        select(ChatMember.id)
        .where(
            and_(
                ChatMember.user_id == b_id,
                ChatMember.chat_id.in_(
                    select(ChatMember.chat_id).where(ChatMember.user_id == a_id)
                ),
            )
        )
        .limit(1)
    ) is not None

def can_view(db, viewer_id: int, target: User, mode: str) -> bool:
    if viewer_id == target.id:
        return True
    if mode == "everyone":
        return True
    if mode == "nobody":
        return False
    if mode == "chats":
        return shares_chat(db, viewer_id, target.id)
    return False
