from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile, File
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select, and_, desc

from server.db.session import SessionLocal
from server.models import Chat, ChatMember, Message, User, ChatUserSetting, BlockedUser
from server.auth import current_user
from server.routes.ws import broadcast_to_users
from server.presence import is_online
from server.privacy import can_view
from server.config import settings

router = APIRouter()

def now():
    return datetime.now(timezone.utc)

def is_member(db, chat_id: int, user_id: int) -> bool:
    return db.scalar(select(ChatMember.id).where(
        and_(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id)
    )) is not None

def chat_users(db, chat_id: int):
    return db.scalars(
        select(User).join(ChatMember, ChatMember.user_id == User.id)
        .where(ChatMember.chat_id == chat_id).order_by(User.id)
    ).all()

def blocked_either(db, a: int, b: int) -> bool:
    return db.scalar(select(BlockedUser.id).where(
        ((BlockedUser.blocker_id == a) & (BlockedUser.blocked_id == b)) |
        ((BlockedUser.blocker_id == b) & (BlockedUser.blocked_id == a))
    ).limit(1)) is not None

def peer_payload(db, viewer_id: int, peer: User | None):
    if not peer: return None
    online_allowed=can_view(db,viewer_id,peer,peer.online_visibility)
    avatar_allowed=can_view(db,viewer_id,peer,peer.avatar_visibility)
    return {
        "id":peer.id,"username":peer.username,"display_name":peer.display_name,"bio":peer.bio or "",
        "online":bool(is_online(peer.id) and online_allowed),
        "has_avatar":bool(peer.avatar_path and avatar_allowed),
        "avatar_url":f"/api/users/{peer.id}/avatar" if peer.avatar_path and avatar_allowed else None,
        "crypto_public_key":peer.crypto_public_key,
    }

def message_payload(msg: Message, sender: User | None = None):
    return {
        "id":msg.id,"chat_id":msg.chat_id,"sender_id":msg.sender_id,
        "sender":{"id":sender.id,"username":sender.username,"display_name":sender.display_name} if sender else None,
        "text":msg.text if not msg.deleted_at else "",
        "encrypted":bool(msg.is_encrypted),"deleted":bool(msg.deleted_at),
        "created_at":msg.created_at.isoformat(),
        "edited_at":msg.edited_at.isoformat() if msg.edited_at else None,
    }

class ChatCreate(BaseModel):
    user_id:int|None=None
    title:str|None=Field(default=None,max_length=120)

class MessageIn(BaseModel):
    text:str=Field(min_length=1,max_length=16000)
    encrypted:bool=False

class MessageEdit(BaseModel):
    text:str=Field(min_length=1,max_length=16000)

class ChatSettingsIn(BaseModel):
    theme:str|None=Field(default=None,max_length=32)
    notifications_enabled:bool|None=None

def chat_response(chat,title,is_group,peer=None):
    return {"id":chat.id,"type":"group" if is_group else "direct","title":title,
            "is_group":bool(is_group),"peer":peer}

@router.get("/chats")
def list_chats(me=Depends(current_user)):
    with SessionLocal() as db:
        chats=db.scalars(select(Chat).join(ChatMember,Chat.id==ChatMember.chat_id)
            .where(ChatMember.user_id==me["id"]).order_by(desc(Chat.id))).all()
        result=[]
        for chat in chats:
            members=chat_users(db,chat.id)
            peer=next((u for u in members if u.id!=me["id"]),None)
            last=db.scalar(select(Message).where(Message.chat_id==chat.id).order_by(desc(Message.id)).limit(1))
            result.append({
                "id":chat.id,"type":"group" if chat.is_group else "direct",
                "title":chat.title if chat.is_group else (peer.display_name if peer else "Личный чат"),
                "is_group":bool(chat.is_group),"peer":peer_payload(db,me["id"],peer),
                "last_message":{
                    "id":last.id,"sender_id":last.sender_id,"text":"" if last.deleted_at else last.text,
                    "encrypted":bool(last.is_encrypted),"created_at":last.created_at.isoformat()
                } if last else None,
            })
        return result

@router.post("/chats")
async def create_chat(data:ChatCreate,me=Depends(current_user)):
    if data.user_id is None and not (data.title and data.title.strip()):
        raise HTTPException(422,"Group title is required")
    if data.user_id==me["id"]: raise HTTPException(400,"Cannot create chat with yourself")
    with SessionLocal() as db:
        target=None
        if data.user_id is not None:
            target=db.get(User,data.user_id)
            if not target or not target.is_active or not target.search_visible:
                raise HTTPException(404,"User not found")
            if blocked_either(db,me["id"],target.id): raise HTTPException(403,"This user is blocked")
            direct_chats=db.scalars(select(Chat).join(ChatMember,ChatMember.chat_id==Chat.id)
                .where(Chat.is_group.is_(False),ChatMember.user_id==me["id"])).all()
            for direct_chat in direct_chats:
                ids=db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id==direct_chat.id)).all()
                if set(ids)=={me["id"],data.user_id}:
                    response=chat_response(direct_chat,target.display_name,False,peer_payload(db,me["id"],target))
                    response["existing"]=True
                    return response

        chat=Chat(title=data.title.strip() if data.title else None,is_group=data.user_id is None,created_at=now())
        db.add(chat); db.flush()
        db.add(ChatMember(chat_id=chat.id,user_id=me["id"]))
        if data.user_id is not None: db.add(ChatMember(chat_id=chat.id,user_id=data.user_id))
        db.commit(); db.refresh(chat)
        peer=peer_payload(db,me["id"],target)
        title=target.display_name if target else chat.title
        chat_type="direct" if data.user_id is not None else "group"
        chat_id=chat.id
        ids=[me["id"]]+([data.user_id] if data.user_id is not None else [])
    await broadcast_to_users(ids,{"type":"chat_created","chat":{
        "id":chat_id,"type":chat_type,"title":title,"is_group":chat_type=="group"}})
    return {"id":chat_id,"type":chat_type,"title":title,"is_group":chat_type=="group","peer":peer}

@router.get("/chats/{chat_id}/messages")
def messages(chat_id:int,before:int|None=Query(default=None),limit:int=Query(default=50,ge=1,le=100),me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]): raise HTTPException(403,"Not a chat member")
        q=select(Message).where(Message.chat_id==chat_id).order_by(desc(Message.id))
        if before: q=q.where(Message.id<before)
        rows=list(reversed(db.scalars(q.limit(limit)).all()))
        if not rows:return []
        sender_ids={m.sender_id for m in rows}
        senders={u.id:u for u in db.scalars(select(User).where(User.id.in_(sender_ids))).all()}
        return [message_payload(m,senders.get(m.sender_id)) for m in rows]

@router.post("/chats/{chat_id}/messages")
async def send_message(chat_id:int,data:MessageIn,me=Depends(current_user)):
    value=data.text.strip()
    if not value:raise HTTPException(422,"Message cannot be empty")
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        chat=db.get(Chat,chat_id)
        if not chat:raise HTTPException(404,"Chat not found")
        members=db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id==chat_id)).all()
        if len(members)==2:
            peer_id=next(x for x in members if x!=me["id"])
            if blocked_either(db,me["id"],peer_id):raise HTTPException(403,"Messaging is blocked")
        msg=Message(chat_id=chat_id,sender_id=me["id"],text=value,is_encrypted=bool(data.encrypted),created_at=now())
        db.add(msg);db.commit();db.refresh(msg)
        payload=message_payload(msg,db.get(User,me["id"]))
    await broadcast_to_users(members,{"type":"new_message","message":payload})
    return payload

@router.patch("/chats/{chat_id}/messages/{message_id}")
async def edit_message(chat_id:int,message_id:int,data:MessageEdit,me=Depends(current_user)):
    with SessionLocal() as db:
        msg=db.get(Message,message_id)
        if not msg or msg.chat_id!=chat_id or msg.sender_id!=me["id"] or msg.deleted_at:
            raise HTTPException(404,"Message not found")
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        msg.text=data.text.strip();msg.edited_at=now();db.commit();db.refresh(msg)
        payload=message_payload(msg,db.get(User,me["id"]))
        members=db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id==chat_id)).all()
    await broadcast_to_users(members,{"type":"message_edited","message":payload})
    return payload

@router.delete("/chats/{chat_id}/messages/{message_id}")
async def delete_message(chat_id:int,message_id:int,me=Depends(current_user)):
    with SessionLocal() as db:
        msg=db.get(Message,message_id)
        if not msg or msg.chat_id!=chat_id or msg.sender_id!=me["id"]:
            raise HTTPException(404,"Message not found")
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        msg.deleted_at=now();msg.text="";db.commit()
        members=db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id==chat_id)).all()
    await broadcast_to_users(members,{"type":"message_deleted","message_id":message_id,"chat_id":chat_id})
    return {"ok":True,"message_id":message_id}

@router.get("/chats/{chat_id}/settings")
def get_chat_settings(chat_id:int,me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        s=db.scalar(select(ChatUserSetting).where(and_(ChatUserSetting.chat_id==chat_id,ChatUserSetting.user_id==me["id"])))
        return {"theme":s.theme if s else "default","notifications_enabled":bool(s.notifications_enabled) if s else True}

@router.patch("/chats/{chat_id}/settings")
def patch_chat_settings(chat_id:int,data:ChatSettingsIn,me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        s=db.scalar(select(ChatUserSetting).where(and_(ChatUserSetting.chat_id==chat_id,ChatUserSetting.user_id==me["id"])))
        if not s:s=ChatUserSetting(chat_id=chat_id,user_id=me["id"]);db.add(s)
        if data.theme is not None:s.theme=data.theme
        if data.notifications_enabled is not None:s.notifications_enabled=data.notifications_enabled
        db.commit()
        return {"ok":True,"theme":s.theme,"notifications_enabled":bool(s.notifications_enabled)}

@router.post("/chats/{chat_id}/wallpaper")
async def upload_wallpaper(chat_id:int,file:UploadFile=File(...),me=Depends(current_user)):
    allowed={"image/jpeg":".jpg","image/png":".png","image/webp":".webp"}
    ext=allowed.get(file.content_type or "")
    if not ext:raise HTTPException(415,"Wallpaper must be JPEG, PNG or WEBP")
    raw=await file.read(8*1024*1024+1)
    if len(raw)>8*1024*1024:raise HTTPException(413,"Wallpaper max size is 8 MB")
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        s=db.scalar(select(ChatUserSetting).where(and_(ChatUserSetting.chat_id==chat_id,ChatUserSetting.user_id==me["id"])))
        if not s:s=ChatUserSetting(chat_id=chat_id,user_id=me["id"]);db.add(s)
        folder=Path(settings.data_dir)/"uploads"/"wallpapers"/str(me["id"])
        folder.mkdir(parents=True,exist_ok=True)
        path=folder/(uuid4().hex+ext);path.write_bytes(raw)
        old=s.wallpaper_path;s.wallpaper_path=str(path.relative_to(Path(settings.data_dir)));db.commit()
        if old:
            old_path=Path(settings.data_dir)/old
            if old_path.exists():old_path.unlink(missing_ok=True)
        return {"ok":True}

@router.delete("/chats/{chat_id}/wallpaper")
def delete_wallpaper(chat_id:int,me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        s=db.scalar(select(ChatUserSetting).where(and_(ChatUserSetting.chat_id==chat_id,ChatUserSetting.user_id==me["id"])))
        if not s or not s.wallpaper_path:return {"ok":True}
        path=Path(settings.data_dir)/s.wallpaper_path;s.wallpaper_path=None;db.commit()
        if path.exists():path.unlink(missing_ok=True)
        return {"ok":True}

@router.get("/chats/{chat_id}/wallpaper")
def get_wallpaper(chat_id:int,me=Depends(current_user)):
    with SessionLocal() as db:
        if not is_member(db,chat_id,me["id"]):raise HTTPException(403,"Not a chat member")
        s=db.scalar(select(ChatUserSetting).where(and_(ChatUserSetting.chat_id==chat_id,ChatUserSetting.user_id==me["id"])))
        if not s or not s.wallpaper_path:raise HTTPException(404,"No wallpaper")
        root=Path(settings.data_dir).resolve();path=(root/s.wallpaper_path).resolve()
        if root not in path.parents or not path.is_file():raise HTTPException(404,"No wallpaper")
        return FileResponse(path,headers={"Cache-Control":"private, max-age=300"})
