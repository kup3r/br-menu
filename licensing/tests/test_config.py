from cryptography.fernet import Fernet
from brlicense.config import Settings

def test_render_public_url_fallback(monkeypatch):
    values={
        'DATABASE_URL':'postgresql://user:password@db/test',
        'BOT_TOKEN':'123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi',
        'ADMIN_IDS':'11', 'WEBHOOK_SECRET':'w'*32, 'KEY_PEPPER':'p'*48,
        'KEY_ENCRYPTION_KEY':Fernet.generate_key().decode(),
        'RENDER_EXTERNAL_URL':'https://license.example.test',
        'SUPPORT_URL':'https://t.me/example',
        'TERMS_TEXT':'Тестовые условия выдачи ключей для проверки системы.'}
    for name,value in values.items():monkeypatch.setenv(name,value)
    monkeypatch.delenv('PUBLIC_URL',raising=False)
    assert Settings.from_env().public_url=='https://license.example.test'
    monkeypatch.setenv('PUBLIC_URL','https://custom.example.test/')
    assert Settings.from_env().public_url=='https://custom.example.test'
