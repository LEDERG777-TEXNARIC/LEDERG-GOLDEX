# LEDERG Messenger

Self-hosted messenger built around FastAPI, SQLAlchemy, SQLite WAL and WebSockets.

## Сейчас уже работает

- регистрация аккаунта по уникальному @username;
- вход по @username и паролю;
- автоматическая выдача и сохранение JWT-сессии;
- поиск пользователей по никнейму или имени;
- создание личного чата без дублей;
- список чатов и последние сообщения;
- история сообщений;
- отправка сообщений до 4096 символов;
- realtime доставка новых сообщений через WebSocket;
- события typing/read;
- мобильная адаптация интерфейса;
- DB-aware /health проверка;
- автоматический локальный JWT secret в \`C:\LEDERG-MESSENGER-DATA\.secret\`;
- автопилот обновления из GitHub и резервное копирование SQLite перед обновлением.

## Локальный запуск

Код: \`C:\LEDERG-MESSENGER\`  
Данные: \`C:\LEDERG-MESSENGER-DATA\`  
Порт: \`8000\`

Открыть на сервере:

\`http://127.0.0.1:8000\`

Для CloudPub публикуй локальный HTTP/WebSocket сервис на \`127.0.0.1:8000\`.

## API

\`POST /api/auth/register\`  
\`POST /api/auth/login\`  
\`GET /api/users/me\`  
\`GET /api/users/search?q=nick\`  
\`GET /api/chats\`  
\`POST /api/chats\`  
\`GET /api/chats/{chat_id}/messages\`  
\`POST /api/chats/{chat_id}/messages\`  
\`WS /ws?token=...\`  
\`GET /health\`

## Что дальше до уровня большого мессенджера

Архитектура готова расширяться без смены клиента: профили и аватары, редактирование/удаление сообщений, реакции, вложения, группы и каналы, unread/read state в БД, уведомления, контакты, блокировки, полноценный presence, голосовые и видеозвонки через WebRTC + STUN/TURN, а также более мощный поиск через FTS5.

LEDERG — собственный проект; цель — сделать Telegram-подобный UX и функциональность, но с собственной реализацией и сервером.
