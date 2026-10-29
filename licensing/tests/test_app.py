from unittest.mock import AsyncMock
from aiogram import Bot
from httpx import ASGITransport, AsyncClient
import pytest
from brlicense.app import create_app
from test_service import service

@pytest.mark.asyncio
async def test_api_and_webhook_authentication(service):
    s=service;bot=Bot(s.settings.bot_token)
    app=create_app(s.settings,database=s.db,bot=bot,register_webhook=False)
    # The endpoint has its own Service, with the same key material and DB.
    app.state.service.clock=s.clock
    app.state.dispatcher.feed_update=AsyncMock()
    async with AsyncClient(transport=ASGITransport(app=app),base_url='https://test') as client:
        assert (await client.get('/health')).status_code==200
        assert (await client.post('/telegram/webhook',json={'update_id':1})).status_code==403
        assert app.state.dispatcher.feed_update.await_count==0
        good=await client.post('/telegram/webhook',json={'update_id':1},headers={'X-Telegram-Bot-Api-Secret-Token':s.settings.webhook_secret})
        assert good.status_code==200 and app.state.dispatcher.feed_update.await_count==1
        key=(await s.create_keys(11,30,1))[0]
        response=await client.post('/v1/licenses/activate',json={'key':s.reveal(key),'device_id':'test-device-123456'})
        assert response.status_code==200
        token=response.json()['token']
        result=await client.post('/v1/licenses/check',json={'device_id':'test-device-123456'},headers={'Authorization':'Bearer '+token})
        assert result.status_code==200
        await s.manage_key(11,key.id,'block')
        result=await client.post('/v1/licenses/check',json={'device_id':'test-device-123456'},headers={'Authorization':'Bearer '+token})
        assert result.status_code==403
    await bot.session.close()
