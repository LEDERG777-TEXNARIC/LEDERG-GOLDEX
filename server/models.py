from datetime import datetime, timezone
from sqlalchemy import String, Text, ForeignKey, DateTime, UniqueConstraint, Boolean, Index, Integer
from sqlalchemy.orm import Mapped, mapped_column
from server.db.session import Base

def now():
    return datetime.now(timezone.utc)

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(Text)
    display_name: Mapped[str] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    avatar_path: Mapped[str | None] = mapped_column(String(255), nullable=True)
    bio: Mapped[str | None] = mapped_column(String(160), nullable=True)
    online_visibility: Mapped[str] = mapped_column(String(16), default="everyone", server_default="everyone")
    avatar_visibility: Mapped[str] = mapped_column(String(16), default="everyone", server_default="everyone")
    search_visible: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    read_receipts: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    typing_visibility: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    session_version: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    crypto_public_key: Mapped[str | None] = mapped_column(Text, nullable=True)

class Chat(Base):
    __tablename__ = "chats"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str | None] = mapped_column(String(120), nullable=True)
    is_group: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)

class ChatMember(Base):
    __tablename__ = "chat_members"
    id: Mapped[int] = mapped_column(primary_key=True)
    chat_id: Mapped[int] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    __table_args__ = (UniqueConstraint("chat_id", "user_id"),)

class BlockedUser(Base):
    __tablename__ = "blocked_users"
    id: Mapped[int] = mapped_column(primary_key=True)
    blocker_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    blocked_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    __table_args__ = (UniqueConstraint("blocker_id", "blocked_id"),)

class ChatUserSetting(Base):
    __tablename__ = "chat_user_settings"
    id: Mapped[int] = mapped_column(primary_key=True)
    chat_id: Mapped[int] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    wallpaper_path: Mapped[str | None] = mapped_column(String(255), nullable=True)
    theme: Mapped[str] = mapped_column(String(32), default="default", server_default="default")
    notifications_enabled: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    __table_args__ = (UniqueConstraint("chat_id", "user_id"),)

class Message(Base):
    __tablename__ = "messages"
    id: Mapped[int] = mapped_column(primary_key=True)
    chat_id: Mapped[int] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), index=True)
    sender_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    text: Mapped[str] = mapped_column(Text)
    is_encrypted: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, index=True)
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

Index("ix_messages_chat_created", Message.chat_id, Message.created_at)
