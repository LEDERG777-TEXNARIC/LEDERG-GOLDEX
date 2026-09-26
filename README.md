# LEDERG Messenger

Self-hosted Telegram-style messenger built around FastAPI, SQLAlchemy, SQLite WAL and WebSockets.

## Уже реализовано

- регистрация и вход по уникальному @username;
- смена имени, @username и bio;
- загрузка/удаление аватара;
- поиск по @нику и имени;
- LIVE presence: зелёная точка только когда пользователь реально онлайн;
- realtime события через WebSocket;
- личные 1:1 чаты с отдельным типом `direct` (это не группа);
- история сообщений;
- отправка, редактирование и удаление сообщений;
- typing/read события с настройками приватности;
- чёрный список;
- настройки видимости онлайн-статуса, аватара и поиска;
- переключатели read receipts и typing;
- смена пароля и отзыв всех остальных сессий через session version;
- локальные темы интерфейса и размер текста;
- индивидуальные настройки каждого чата;
- загрузка собственных обоев для каждого чата;
- приватная выдача аватаров и обоев только авторизованным участникам;
- E2EE для личных сообщений при наличии ключей на устройствах обоих пользователей: браузер шифрует текст AES-GCM через общий ECDH P-256 ключ, сервер сохраняет шифртекст;
- автоматические SQLite migration/DB integrity checks;
- WAL и `PRAGMA optimize`;
- автопилот GitHub: backup БД, установка зависимостей, health-check, known-good revision и автоматический rollback.

## Локально

Код: `C:LEDERG-MESSENGER`  
Данные: `C:LEDERG-MESSENGER-DATA`  
Порт: `8000`

Открыть:

`http://127.0.0.1:8000`

Для CloudPub публикуй HTTP/WebSocket сервис на `127.0.0.1:8000`.

## Основные API

`POST /api/auth/register`  
`POST /api/auth/login`  
`POST /api/auth/password`  
`POST /api/auth/logout-all`  
`GET /api/users/me`  
`PATCH /api/users/me`  
`POST /api/users/me/avatar`  
`DELETE /api/users/me/avatar`  
`POST /api/users/me/crypto-key`  
`GET /api/users/search?q=nick`  
`POST /api/users/{user_id}/block`  
`DELETE /api/users/{user_id}/block`  
`GET /api/users/blocked`  
`GET /api/chats`  
`POST /api/chats`  
`GET /api/chats/{chat_id}/messages`  
`POST /api/chats/{chat_id}/messages`  
`PATCH /api/chats/{chat_id}/messages/{message_id}`  
`DELETE /api/chats/{chat_id}/messages/{message_id}`  
`GET/PATCH /api/chats/{chat_id}/settings`  
`POST/DELETE/GET /api/chats/{chat_id}/wallpaper`  
`WS /ws?token=...`  
`GET /health`

## Приватность

LEDERG не использует номер телефона как идентификатор аккаунта. Пользователь сам выбирает, кому показывать online и аватар, и может полностью выключить поиск по себе.

Для HTTP API используется Bearer JWT. Access log Uvicorn отключён, чтобы локальный сервер не писал стандартные HTTP access-log строки с адресами клиентов.

E2EE в текущем web-клиенте является device-local: приватный ключ хранится в браузере. Это означает, что новый браузер/новое устройство получает новый ключ и не сможет расшифровать старую историю без переноса ключа. Реализация не является криптографически аудированной и не защищает от компрометации устройства или вредоносного изменения клиента/сервера.

## Автопилот

`LEDERG-MESSENGER-SERVER.bat` теперь является ASCII/no-BOM launcher и запускает `scripts/autopilot.ps1`.

Стабильная ревизия сохраняется в:

`C:LEDERG-MESSENGER-DATAlast-known-good.txt`

Логи:

`C:LEDERG-MESSENGER-DATAlogsautopilot.log`  
`C:LEDERG-MESSENGER-DATAlogsserver.log`

Перед обновлением SQLite backup создаётся в:

`C:LEDERG-MESSENGER-DATAackups`

## Дальше

Следующий слой можно расширять без ломки текущего ядра: реакции, пересылка, вложения и медиа, группы/каналы, unread state, уведомления, контакты, более полноценные устройства/сессии, WebRTC звонки через STUN/TURN, а также отдельный audited E2EE протокол с переносом ключей между устройствами.
