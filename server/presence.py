from threading import Lock

_online_users: set[int] = set()
_lock = Lock()

def mark_online(user_id: int) -> bool:
    with _lock:
        was_online = user_id in _online_users
        _online_users.add(user_id)
        return not was_online

def mark_offline(user_id: int) -> bool:
    with _lock:
        if user_id not in _online_users:
            return False
        _online_users.remove(user_id)
        return True

def is_online(user_id: int) -> bool:
    with _lock:
        return user_id in _online_users
