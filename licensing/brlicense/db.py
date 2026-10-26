from sqlalchemy import BigInteger, Boolean, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.engine import make_url

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = 'license_users'
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    terms_version: Mapped[str] = mapped_column(String(64), default='')
    created_at: Mapped[int] = mapped_column(BigInteger)

class Plan(Base):
    __tablename__ = 'license_plans'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    title: Mapped[str] = mapped_column(String(80))
    days: Mapped[int] = mapped_column(Integer)
    stars: Mapped[int] = mapped_column(Integer)
    active: Mapped[bool] = mapped_column(Boolean, default=True)

class License(Base):
    __tablename__ = 'licenses'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True)
    key_cipher: Mapped[str] = mapped_column(Text)
    owner_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    days: Mapped[int] = mapped_column(Integer)
    max_devices: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(24), default='active')
    starts_on_activation: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[int] = mapped_column(BigInteger)
    activated_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    expires_at: Mapped[int | None] = mapped_column(BigInteger, nullable=True)

class Order(Base):
    __tablename__ = 'license_orders'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[int] = mapped_column(BigInteger)
    title: Mapped[str] = mapped_column(String(80))
    days: Mapped[int] = mapped_column(Integer)
    stars: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24), default='pending')
    target_license_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    license_id: Mapped[str | None] = mapped_column(ForeignKey('licenses.id'), nullable=True)
    created_at: Mapped[int] = mapped_column(BigInteger)

class Payment(Base):
    __tablename__ = 'license_payments'
    charge_id: Mapped[str] = mapped_column(String(256), primary_key=True)
    order_id: Mapped[str] = mapped_column(ForeignKey('license_orders.id'), unique=True)
    user_id: Mapped[int] = mapped_column(BigInteger)
    stars: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24), default='paid')
    created_at: Mapped[int] = mapped_column(BigInteger)

class Device(Base):
    __tablename__ = 'license_devices'
    __table_args__ = (UniqueConstraint('license_id', 'device_hash'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    license_id: Mapped[str] = mapped_column(ForeignKey('licenses.id'))
    device_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[int] = mapped_column(BigInteger)

class Session(Base):
    __tablename__ = 'license_sessions'
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    license_id: Mapped[str] = mapped_column(ForeignKey('licenses.id'))
    device_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[int] = mapped_column(BigInteger)

class RateWindow(Base):
    __tablename__ = 'license_rate_windows'
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    window: Mapped[int] = mapped_column(BigInteger)
    count: Mapped[int] = mapped_column(Integer)

class Audit(Base):
    __tablename__ = 'license_audit'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    actor_id: Mapped[int] = mapped_column(BigInteger)
    action: Mapped[str] = mapped_column(String(40))
    target: Mapped[str] = mapped_column(String(80))
    created_at: Mapped[int] = mapped_column(BigInteger)

class Database:
    def __init__(self, dsn):
        if dsn.startswith('postgres://'):
            dsn = dsn.replace('postgres://', 'postgresql://', 1)
        url = make_url(dsn)
        if url.drivername == 'postgresql':
            query = dict(url.query)
            # libpq-only option present in some Neon copy/paste DSNs. asyncpg
            # uses its own TLS implementation and does not accept this argument.
            query.pop('channel_binding', None)
            if 'sslmode' in query:
                query['ssl'] = query.pop('sslmode')
            url = url.set(drivername='postgresql+asyncpg', query=query)
        self.engine = create_async_engine(url, pool_pre_ping=True)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def initialize(self):
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    async def close(self):
        await self.engine.dispose()
