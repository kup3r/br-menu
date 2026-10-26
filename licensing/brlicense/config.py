from dataclasses import dataclass
import os
from urllib.parse import urlparse
from cryptography.fernet import Fernet
from dotenv import load_dotenv

@dataclass(frozen=True)
class Settings:
    database_url: str
    bot_token: str
    admin_ids: frozenset[int]
    webhook_secret: str
    key_pepper: str
    encryption_key: str
    public_url: str
    support_url: str
    terms: str

    @classmethod
    def from_env(cls):
        load_dotenv()
        def required(name):
            value = os.environ.get(name, '').strip()
            if not value:
                raise ValueError(f'Задай {name} в переменных окружения')
            return value
        result = cls(required('DATABASE_URL'), required('BOT_TOKEN'),
            frozenset(int(x.strip()) for x in required('ADMIN_IDS').split(',')),
            required('WEBHOOK_SECRET'), required('KEY_PEPPER'), required('KEY_ENCRYPTION_KEY'),
            required('PUBLIC_URL').rstrip('/'), required('SUPPORT_URL'), required('TERMS_TEXT'))
        if not result.admin_ids or any(x <= 0 for x in result.admin_ids):
            raise ValueError('ADMIN_IDS: нужны числовые Telegram ID')
        if min(len(result.webhook_secret), len(result.key_pepper)) < 32:
            raise ValueError('WEBHOOK_SECRET и KEY_PEPPER: минимум 32 случайных символа')
        if not all(x.isalnum() or x in '_-' for x in result.webhook_secret):
            raise ValueError('WEBHOOK_SECRET: только буквы, цифры, _ и -')
        Fernet(result.encryption_key.encode())
        for value in [result.public_url, result.support_url]:
            parsed = urlparse(value)
            if parsed.scheme != 'https' or not parsed.netloc:
                raise ValueError('PUBLIC_URL и SUPPORT_URL должны начинаться с https://')
        if not 20 <= len(result.terms) <= 2500:
            raise ValueError('TERMS_TEXT: от 20 до 2500 символов')
        return result
