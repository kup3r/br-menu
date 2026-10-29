import hashlib
import hmac
import secrets
import time
from uuid import uuid4
from cryptography.fernet import Fernet
from sqlalchemy import select, func, delete, case
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from .db import User, Plan, License, Order, Payment, Device, Session, Audit, RateWindow

class LicenseError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)

def uid():
    return str(uuid4())

class Service:
    def __init__(self, db, settings, clock=time.time):
        self.db, self.settings, self.clock = db, settings, clock
        self.cipher = Fernet(settings.encryption_key.encode())
        self.terms_version = hashlib.sha256(settings.terms.encode()).hexdigest()

    def now(self):
        return int(self.clock())

    def digest(self, category, value):
        return hmac.new(self.settings.key_pepper.encode(), f'{category}:{value}'.encode(), hashlib.sha256).hexdigest()

    def reveal(self, license):
        return self.cipher.decrypt(license.key_cipher.encode()).decode()

    def admin(self, user_id):
        if user_id not in self.settings.admin_ids:
            raise LicenseError('FORBIDDEN', 'Нет доступа')

    def audit(self, db, actor, action, target):
        db.add(Audit(id=uid(), actor_id=actor, action=action, target=target, created_at=self.now()))

    async def accept_terms(self, user_id):
        async with self.db.sessions.begin() as db:
            insert = pg_insert if db.bind.dialect.name == 'postgresql' else sqlite_insert
            statement = insert(User).values(id=user_id, terms_version=self.terms_version, created_at=self.now())
            await db.execute(statement.on_conflict_do_update(index_elements=[User.id], set_={'terms_version': self.terms_version}))

    async def add_plan(self, actor, title, days, stars):
        self.admin(actor)
        if not title.strip() or len(title) > 80 or not 1 <= days <= 3650 or not 1 <= stars <= 10000:
            raise LicenseError('INPUT', 'Название до 80 символов, срок 1–3650 дней, цена 1–10000 Stars')
        plan = Plan(id=uid(), title=title.strip(), days=days, stars=stars, active=True)
        async with self.db.sessions.begin() as db:
            db.add(plan); self.audit(db, actor, 'plan.create', plan.id)
        return plan

    async def plans(self, all=False):
        async with self.db.sessions() as db:
            statement = select(Plan).order_by(Plan.days, Plan.id)
            if not all:
                statement = statement.where(Plan.active.is_(True))
            return list((await db.scalars(statement)).all())

    async def toggle_plan(self, actor, id):
        self.admin(actor)
        async with self.db.sessions.begin() as db:
            plan = await db.get(Plan, id, with_for_update=True)
            if not plan: raise LicenseError('NOT_FOUND', 'Тариф не найден')
            plan.active = not plan.active
            self.audit(db, actor, 'plan.toggle', id)

    def _new_license(self, db, days, devices=1, immediate=False, owner=None):
        key = 'BR-' + secrets.token_hex(16).upper()
        license = License(id=uid(), key_hash=self.digest('key', key), key_cipher=self.cipher.encrypt(key.encode()).decode(),
            owner_id=owner, days=days, max_devices=devices, status='active', starts_on_activation=not immediate,
            created_at=self.now(), activated_at=None, expires_at=self.now()+days*86400 if immediate else None)
        db.add(license)
        return license

    async def create_keys(self, actor, days, count, devices=1, immediate=False):
        self.admin(actor)
        if not 1 <= days <= 3650 or not 1 <= count <= 100 or not 1 <= devices <= 5:
            raise LicenseError('INPUT', 'Срок 1–3650 дней, количество 1–100, устройства 1–5')
        async with self.db.sessions.begin() as db:
            result = [self._new_license(db, days, devices, immediate) for _ in range(count)]
            self.audit(db, actor, 'keys.create', f'{count} x {days} days; devices={devices}; immediate={immediate}')
        return result

    async def create_order(self, user, plan_id, target=None):
        async with self.db.sessions.begin() as db:
            account = await db.get(User, user)
            if not account or account.terms_version != self.terms_version:
                raise LicenseError('TERMS', 'Сначала прими условия покупки')
            plan = await db.get(Plan, plan_id)
            if not plan or not plan.active: raise LicenseError('PLAN', 'Тариф недоступен')
            if target:
                license = await db.get(License, target)
                if not license or license.owner_id != user or license.status != 'active':
                    raise LicenseError('LICENSE', 'Этот ключ нельзя продлить')
            order = Order(id=uid(), user_id=user, title=plan.title, days=plan.days, stars=plan.stars,
                status='pending', target_license_id=target, created_at=self.now())
            db.add(order)
        return order

    async def checkout(self, user, payload, currency, amount):
        async with self.db.sessions() as db:
            order = await db.get(Order, payload)
            if not order or order.user_id != user or currency != 'XTR' or order.stars != amount or order.status != 'pending' or self.now()-order.created_at > 86400:
                raise LicenseError('ORDER', 'Счёт недоступен. Открой новый счёт в боте')

    def extend(self, license, days):
        license.days += days
        if license.expires_at is not None:
            license.expires_at = max(self.now(), license.expires_at) + days*86400

    async def receive_payment(self, user, payload, currency, amount, charge):
        if not charge or len(charge) > 256:
            raise LicenseError('PAYMENT', 'Некорректный идентификатор платежа')
        async with self.db.sessions.begin() as db:
            # Telegram retries and concurrent deliveries serialize on the immutable order.
            order = await db.get(Order, payload, with_for_update=True)
            if not order or order.user_id != user or currency != 'XTR' or order.stars != amount:
                raise LicenseError('PAYMENT', 'Платёж не совпадает со счётом')
            payment = await db.get(Payment, charge)
            if payment:
                if payment.order_id != order.id or payment.user_id != user:
                    raise LicenseError('PAYMENT', 'Платёж уже относится к другому счёту')
                return await db.get(License, order.license_id)
            if order.status != 'pending':
                raise LicenseError('PAYMENT', 'Для этого счёта уже учтена другая оплата')
            license = await db.get(License, order.target_license_id, with_for_update=True) if order.target_license_id else None
            if license:
                if license.owner_id != user: raise LicenseError('OWNER', 'Владелец ключа изменён')
                self.extend(license, order.days)
            else:
                license = self._new_license(db, order.days, owner=user)
                await db.flush()
            order.license_id, order.status = license.id, 'paid'
            db.add(Payment(charge_id=charge, order_id=order.id, user_id=user, stars=amount, status='paid', created_at=self.now()))
            self.audit(db, user, 'payment.received', order.id)
        return license

    async def my_keys(self, user):
        async with self.db.sessions() as db:
            return list((await db.scalars(select(License).where(License.owner_id==user).order_by(License.created_at.desc()).limit(30))).all())

    async def recent_keys(self, actor, page=0):
        self.admin(actor)
        if not 0 <= page <= 100000: raise LicenseError('INPUT','Некорректная страница')
        async with self.db.sessions() as db:
            return list((await db.scalars(select(License).order_by(License.created_at.desc(),License.id).offset(page*20).limit(21))).all())

    async def find_key(self, actor, key):
        self.admin(actor)
        async with self.db.sessions() as db:
            license = await db.scalar(select(License).where(License.key_hash==self.digest('key', key.strip().upper())))
            if not license: raise LicenseError('NOT_FOUND', 'Ключ не найден')
            return license

    async def get_license(self, actor, id):
        self.admin(actor)
        async with self.db.sessions() as db:
            license = await db.get(License, id)
            if not license: raise LicenseError('NOT_FOUND', 'Ключ не найден')
            return license

    async def manage_key(self, actor, id, action, days=0):
        self.admin(actor)
        async with self.db.sessions.begin() as db:
            license = await db.get(License, id, with_for_update=True)
            if not license: raise LicenseError('NOT_FOUND', 'Ключ не найден')
            if action=='extend':
                if not 1 <= days <= 3650: raise LicenseError('INPUT', 'Срок: 1–3650 дней')
                self.extend(license, days)
            elif action=='block':
                if license.status in {'refunded','refund_pending'}: raise LicenseError('REFUND','Для ключа уже оформляется возврат')
                license.status='blocked'
            elif action=='unblock':
                if license.status in {'refunded', 'refund_pending'}:
                    raise LicenseError('REFUND', 'Ключ с возвратом нельзя разблокировать')
                license.status='active'
            elif action=='reset':
                await db.execute(delete(Session).where(Session.license_id==id))
                await db.execute(delete(Device).where(Device.license_id==id))
            else: raise LicenseError('INPUT', 'Неизвестное действие')
            self.audit(db, actor, 'key.'+action, id)
        return license

    async def rate_limit(self, address, scope, limit):
        # Database atomic upsert: shared across workers/restarts, no raw IP stored.
        now = self.now(); window = now//60; key=self.digest('rate', scope+':'+address)
        async with self.db.sessions.begin() as db:
            insert = pg_insert if db.bind.dialect.name=='postgresql' else sqlite_insert
            statement=insert(RateWindow).values(id=key, window=window, count=1)
            count=await db.scalar(statement.on_conflict_do_update(index_elements=[RateWindow.id], set_={
                'window':window, 'count':case((RateWindow.window==window, RateWindow.count+1), else_=1)
            }).returning(RateWindow.count))
            await db.execute(delete(RateWindow).where(RateWindow.window < window-60))
        if count > limit: raise LicenseError('RATE_LIMIT', 'Слишком много запросов. Подожди минуту')

    def available(self, license):
        if license.status != 'active': raise LicenseError('BLOCKED', 'Ключ заблокирован или платёж возвращён')
        if license.expires_at is not None and license.expires_at <= self.now():
            raise LicenseError('EXPIRED', 'Срок ключа закончился')

    async def activate(self, key, device):
        async with self.db.sessions.begin() as db:
            license = await db.scalar(select(License).where(License.key_hash==self.digest('key',key.strip().upper())).with_for_update())
            if not license: raise LicenseError('INVALID_KEY', 'Ключ не найден')
            self.available(license)
            hashed=self.digest('device', device)
            exists=await db.scalar(select(Device).where(Device.license_id==license.id,Device.device_hash==hashed))
            if not exists:
                count=await db.scalar(select(func.count()).select_from(Device).where(Device.license_id==license.id))
                if count >= license.max_devices: raise LicenseError('DEVICE_LIMIT','Лимит устройств. Обратись в поддержку для сброса')
                db.add(Device(id=uid(),license_id=license.id,device_hash=hashed,created_at=self.now()))
            if license.activated_at is None:
                license.activated_at=self.now()
                if license.expires_at is None: license.expires_at=self.now()+license.days*86400
            await db.execute(delete(Session).where(Session.license_id==license.id,Session.device_hash==hashed))
            token=secrets.token_urlsafe(32)
            end=min(self.now()+3600,license.expires_at)
            db.add(Session(token_hash=self.digest('session',token),license_id=license.id,device_hash=hashed,expires_at=end))
        return {'token':token,'expires_at':license.expires_at,'session_expires_at':end}

    async def check(self, token, device):
        async with self.db.sessions.begin() as db:
            session=await db.get(Session,self.digest('session',token))
            if not session or session.device_hash!=self.digest('device',device):
                raise LicenseError('SESSION','Сессия недействительна')
            if session.expires_at <= self.now(): raise LicenseError('SESSION_EXPIRED','Войди снова')
            # Key lock serializes with revocation/reset/extension in PostgreSQL.
            license=await db.get(License,session.license_id,with_for_update=True)
            self.available(license)
            # A reset may have happened while we waited for the key lock.
            await db.refresh(session)
            exists=await db.scalar(select(Device.id).where(Device.license_id==license.id,Device.device_hash==session.device_hash))
            if not exists: raise LicenseError('SESSION','Привязка сброшена')
            session.expires_at=min(self.now()+3600,license.expires_at)
            return {'valid':True,'expires_at':license.expires_at,'session_expires_at':session.expires_at}

    async def stats(self, actor):
        self.admin(actor)
        async with self.db.sessions() as db:
            keys=await db.scalar(select(func.count()).select_from(License))
            active=await db.scalar(select(func.count()).select_from(License).where(License.status=='active', (License.expires_at.is_(None)) | (License.expires_at>self.now())))
            users=await db.scalar(select(func.count()).select_from(User))
            paid=await db.scalar(select(func.coalesce(func.sum(Payment.stars),0)).where(Payment.status=='paid'))
            return f'Ключей: {keys}\nДействующих / ожидающих активации: {active}\nПокупателей, принявших условия: {users}\nОплачено без возвратов: {paid} Stars'

    async def payments(self, actor):
        self.admin(actor)
        async with self.db.sessions() as db:
            return list((await db.scalars(select(Payment).order_by(Payment.created_at.desc()).limit(20))).all())

    async def prepare_refund(self, actor, order_id):
        self.admin(actor)
        async with self.db.sessions.begin() as db:
            payment=await db.scalar(select(Payment).where(Payment.order_id==order_id).with_for_update())
            if not payment or payment.status!='paid': raise LicenseError('REFUND','Платёж уже возвращён или ожидает проверки возврата')
            order=await db.get(Order,order_id)
            license=await db.get(License,order.license_id,with_for_update=True)
            license.status='refund_pending';payment.status='refund_pending'
            self.audit(db,actor,'refund.request',order_id)
        return payment

    async def record_refund(self, charge, user):
        async with self.db.sessions.begin() as db:
            payment=await db.get(Payment,charge,with_for_update=True)
            if not payment or payment.user_id!=user: raise LicenseError('REFUND','Неизвестный платёж')
            order=await db.get(Order,payment.order_id)
            license=await db.get(License,order.license_id,with_for_update=True)
            # Entire key is suspended, including later renewals. Admin resolves
            # mixed renewal/refund cases explicitly; never re-enable on timeout.
            license.status='refunded';payment.status='refunded'
            await db.execute(delete(Session).where(Session.license_id==license.id))
            self.audit(db,user,'refund.confirmed',order.id)
