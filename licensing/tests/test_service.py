import asyncio
import os
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet
from sqlalchemy import select, func
from brlicense.config import Settings
from brlicense.db import Database, Base, License, Payment
from brlicense.service import Service, LicenseError

@pytest_asyncio.fixture
async def service(tmp_path):
    url=os.environ.get('TEST_DATABASE_URL',f'sqlite+aiosqlite:///{tmp_path}/test.sqlite')
    db=Database(url)
    async with db.engine.begin() as c:
        await c.run_sync(Base.metadata.drop_all)
    await db.initialize()
    settings=Settings(url,'123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi',frozenset({11}),'w'*32,'p'*48,
        Fernet.generate_key().decode(),'https://example.test','https://t.me/example','Тестовые условия: доступ по ключу на выбранный срок.')
    clock=[1_800_000_000]
    s=Service(db,settings,lambda:clock[0]);s.test_clock=clock
    yield s
    await db.close()

async def order(s,user=22,days=30):
    p=await s.add_plan(11,'Доступ',days,150)
    await s.accept_terms(user)
    return await s.create_order(user,p.id)

@pytest.mark.asyncio
async def test_paid_key_exactly_once_and_owner(service):
    s=service;o=await order(s)
    await s.checkout(22,o.id,'XTR',150)
    a=await s.receive_payment(22,o.id,'XTR',150,'charge-A')
    b=await s.receive_payment(22,o.id,'XTR',150,'charge-A')
    assert a.id==b.id and a.expires_at is None
    assert len(await s.my_keys(22))==1 and await s.my_keys(23)==[]
    for args in [(23,o.id,'XTR',150,'B'),(22,o.id,'USD',150,'B'),(22,o.id,'XTR',1,'B'),(22,o.id,'XTR',150,'B')]:
        with pytest.raises(LicenseError): await s.receive_payment(*args)
    async with s.db.sessions() as db:
        assert await db.scalar(select(func.count()).select_from(Payment))==1

@pytest.mark.asyncio
async def test_terms_and_immutable_order_price(service):
    s=service;p=await s.add_plan(11,'Тариф',7,50)
    with pytest.raises(LicenseError):await s.create_order(22,p.id)
    await s.accept_terms(22);o=await s.create_order(22,p.id)
    await s.toggle_plan(11,p.id)
    await s.checkout(22,o.id,'XTR',50) # accepted invoice keeps its price
    with pytest.raises(LicenseError):await s.create_order(22,p.id)
    s.test_clock[0]+=86401
    with pytest.raises(LicenseError):await s.checkout(22,o.id,'XTR',50)
    # A captured payment is fulfilled even if receipt delivery was delayed.
    key=await s.receive_payment(22,o.id,'XTR',50,'late-charge');assert key.days==7

@pytest.mark.asyncio
async def test_activation_device_limit_expiry_and_reset(service):
    s=service;k=(await s.create_keys(11,7,1))[0];raw=s.reveal(k)
    response=await s.activate(raw,'device-one-123456');assert response['expires_at']==s.now()+7*86400
    with pytest.raises(LicenseError,match='Лимит устройств'): await s.activate(raw,'device-two-123456')
    assert (await s.check(response['token'],'device-one-123456'))['valid']
    with pytest.raises(LicenseError):await s.check(response['token'],'wrong-device-12345')
    await s.manage_key(11,k.id,'reset')
    with pytest.raises(LicenseError):await s.check(response['token'],'device-one-123456')
    response=await s.activate(raw,'device-two-123456')
    await s.manage_key(11,k.id,'block')
    with pytest.raises(LicenseError):await s.check(response['token'],'device-two-123456')
    await s.manage_key(11,k.id,'unblock')
    s.test_clock[0]+=7*86400
    with pytest.raises(LicenseError) as err:await s.activate(raw,'device-two-123456')
    assert err.value.code=='EXPIRED'
    await s.manage_key(11,k.id,'extend',3)
    renewed=await s.activate(raw,'device-two-123456');assert renewed['expires_at']==s.now()+3*86400

@pytest.mark.asyncio
async def test_giveaway_duration_start_and_admin_permissions(service):
    s=service
    with pytest.raises(LicenseError):await s.create_keys(22,30,1)
    with pytest.raises(LicenseError):await s.stats(22)
    with pytest.raises(LicenseError):await s.manage_key(22,'anything','unblock')
    keys=await s.create_keys(11,5,100)
    assert len({s.reveal(k) for k in keys})==100
    k=keys[0];await s.manage_key(11,k.id,'extend',2)
    s.test_clock[0]+=10*86400
    result=await s.activate(s.reveal(k),'my-device-1234567')
    assert result['expires_at']==s.now()+7*86400
    immediate=(await s.create_keys(11,1,1,immediate=True))[0]
    s.test_clock[0]+=86400
    with pytest.raises(LicenseError):await s.activate(s.reveal(immediate),'my-device-1234567')

@pytest.mark.asyncio
async def test_renewal_refund_blocks_sessions_and_replays(service):
    s=service;o=await order(s);k=await s.receive_payment(22,o.id,'XTR',150,'charge-refund')
    raw=s.reveal(k);session=await s.activate(raw,'device-one-123456')
    p=await s.add_plan(11,'Продление',7,40)
    renew=await s.create_order(22,p.id,k.id)
    k=await s.receive_payment(22,renew.id,'XTR',40,'renew-charge')
    assert k.days==37 and k.expires_at==s.now()+37*86400
    await s.prepare_refund(11,o.id)
    with pytest.raises(LicenseError):await s.check(session['token'],'device-one-123456')
    await s.record_refund('charge-refund',22);await s.record_refund('charge-refund',22)
    with pytest.raises(LicenseError):await s.manage_key(11,k.id,'unblock')
    with pytest.raises(LicenseError):await s.manage_key(11,k.id,'block')
    replay=await s.receive_payment(22,o.id,'XTR',150,'charge-refund');assert replay.status=='refunded'
    with pytest.raises(LicenseError):await s.activate(raw,'device-one-123456')

@pytest.mark.asyncio
async def test_session_lifetime_rate_limit_and_plaintext_not_stored(service):
    s=service;k=(await s.create_keys(11,1,1))[0];raw=s.reveal(k)
    assert raw not in k.key_hash and raw not in k.key_cipher
    session=await s.activate(raw,'device-one-123456')
    s.test_clock[0]+=3601
    with pytest.raises(LicenseError) as error:await s.check(session['token'],'device-one-123456')
    assert error.value.code=='SESSION_EXPIRED'
    for _ in range(10):await s.rate_limit('127.0.0.1','activate',10)
    with pytest.raises(LicenseError) as error:await s.rate_limit('127.0.0.1','activate',10)
    assert error.value.code=='RATE_LIMIT'
    s.test_clock[0]+=60;await s.rate_limit('127.0.0.1','activate',10)

@pytest.mark.asyncio
async def test_postgres_concurrent_payment_and_last_device(service):
    s=service
    if s.db.engine.dialect.name!='postgresql':pytest.skip('Real row locks are tested with PostgreSQL in CI')
    o=await order(s)
    receipts=await asyncio.gather(*(s.receive_payment(22,o.id,'XTR',150,'same-charge') for _ in range(5)))
    assert len({x.id for x in receipts})==1
    raw=s.reveal(receipts[0])
    results=await asyncio.gather(*(s.activate(raw,'concurrent-device-'+str(i)) for i in range(5)),return_exceptions=True)
    assert sum(isinstance(x,dict) for x in results)==1
    assert sum(isinstance(x,LicenseError) and x.code=='DEVICE_LIMIT' for x in results)==4
