from contextlib import asynccontextmanager
import hmac
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import text
from aiogram import Bot
from aiogram.client.default import DefaultBotProperties
from aiogram.types import Update
from .config import Settings
from .db import Database
from .service import Service, LicenseError
from .bot import build_dispatcher

class Activation(BaseModel):
    key: str = Field(min_length=10,max_length=128)
    device_id: str = Field(min_length=16,max_length=128,pattern=r'^[A-Za-z0-9_-]+$')

class Check(BaseModel):
    device_id: str = Field(min_length=16,max_length=128,pattern=r'^[A-Za-z0-9_-]+$')

def create_app(settings=None, *, database=None, bot=None, register_webhook=True):
    settings=settings or Settings.from_env()
    db=database or Database(settings.database_url)
    service=Service(db,settings)
    telegram=bot or Bot(settings.bot_token,default=DefaultBotProperties(parse_mode='HTML'))
    dp=build_dispatcher(service,telegram)

    @asynccontextmanager
    async def lifespan(app):
        await db.initialize()
        if register_webhook:
            await telegram.set_webhook(settings.public_url+'/telegram/webhook',secret_token=settings.webhook_secret,
                allowed_updates=['message','callback_query','pre_checkout_query'],drop_pending_updates=False)
        yield
        await dp.storage.close()
        await telegram.session.close()
        await db.close()

    app=FastAPI(title='BR License API',lifespan=lifespan,docs_url=None,redoc_url=None)
    app.state.service=service
    app.state.dispatcher=dp

    @app.exception_handler(LicenseError)
    async def error(request,e):
        status=429 if e.code=='RATE_LIMIT' else 403 if e.code in {'BLOCKED','EXPIRED','DEVICE_LIMIT'} else 401
        return JSONResponse(status_code=status,content={'code':e.code,'message':e.message})

    @app.get('/health')
    async def health():
        async with db.sessions() as session:
            await session.execute(text('SELECT 1'))
        return {'status':'ok'}

    @app.post('/telegram/webhook')
    async def webhook(request: Request):
        secret=request.headers.get('X-Telegram-Bot-Api-Secret-Token','')
        if not hmac.compare_digest(secret,settings.webhook_secret): raise HTTPException(403,'Forbidden')
        # Synchronous acknowledgement: failed database/Telegram work returns 500,
        # allowing Telegram delivery retry. Payment idempotency lives in PostgreSQL.
        if len(await request.body()) > 1024*1024: raise HTTPException(413,'Update too large')
        update=Update.model_validate(await request.json(),context={'bot':telegram})
        await dp.feed_update(telegram,update)
        return {'ok':True}

    @app.post('/v1/licenses/activate')
    async def activate(payload: Activation,request: Request):
        address=request.client.host if request.client else 'unknown'
        await service.rate_limit(address,'activation',10)
        return await service.activate(payload.key,payload.device_id)

    @app.post('/v1/licenses/check')
    async def check(payload: Check,request: Request):
        authorization=request.headers.get('Authorization','')
        if not authorization.startswith('Bearer ') or len(authorization)>256:
            raise HTTPException(401,'Bearer token required')
        address=request.client.host if request.client else 'unknown'
        await service.rate_limit(address,'check',600)
        return await service.check(authorization[7:],payload.device_id)
    return app
