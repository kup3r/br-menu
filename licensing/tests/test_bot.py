from datetime import datetime, timezone
from aiogram import Bot
from aiogram.client.session.base import BaseSession
from aiogram.types import Message, Chat, User, Update, CallbackQuery, SuccessfulPayment
from brlicense.bot import build_dispatcher, Form
from test_service import service, order
import pytest

class FakeTelegram(BaseSession):
    def __init__(self): super().__init__(); self.calls=[]
    async def close(self): pass
    async def make_request(self,bot,method,timeout=None):
        self.calls.append(method)
        if method.__returning__ is bool:return True
        return Message(message_id=99,date=datetime.now(timezone.utc),chat=Chat(id=int(method.chat_id),type='private'),text='ok')
    async def stream_content(self,*a,**k):
        yield b''

def message(user,text=None,**kwargs):
    return Message(message_id=1,date=datetime.now(timezone.utc),chat=Chat(id=user,type='private'),
        from_user=User(id=user,is_bot=False,first_name='User'),text=text,**kwargs)

@pytest.mark.asyncio
async def test_forged_admin_callback_and_fsm(service):
    s=service;transport=FakeTelegram();bot=Bot(s.settings.bot_token,session=transport);dp=build_dispatcher(s,bot)
    callback=CallbackQuery(id='x',from_user=User(id=22,is_bot=False,first_name='Not Admin'),chat_instance='private',
        message=message(22),data='a:keys')
    await dp.feed_update(bot,Update(update_id=1,callback_query=callback))
    assert transport.calls[-1].text=='Нет доступа'
    context=dp.fsm.get_context(bot=bot,chat_id=22,user_id=22)
    await context.set_state(Form.create_keys)
    await dp.feed_update(bot,Update(update_id=2,message=message(22,'30 100 1 activation')))
    assert 'Нет доступа' in transport.calls[-1].text
    assert 'Ключей: 0' in await s.stats(11)
    await dp.storage.close();await bot.session.close()

@pytest.mark.asyncio
async def test_payment_handler_duplicate_and_admin_menu(service):
    s=service;transport=FakeTelegram();bot=Bot(s.settings.bot_token,session=transport);dp=build_dispatcher(s,bot)
    await dp.feed_update(bot,Update(update_id=1,message=message(11,'/admin')))
    assert transport.calls[-1].reply_markup.inline_keyboard[0][0].text=='Создать ключи'
    o=await order(s)
    payment=SuccessfulPayment(currency='XTR',total_amount=150,invoice_payload=o.id,telegram_payment_charge_id='telegram-charge',provider_payment_charge_id='')
    for update_id in [2,3]:
        await dp.feed_update(bot,Update(update_id=update_id,message=message(22,successful_payment=payment)))
    assert len(await s.my_keys(22))==1
    assert 'BR-' in transport.calls[-1].text
    await dp.storage.close();await bot.session.close()
