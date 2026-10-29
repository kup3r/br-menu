import secrets
from cryptography.fernet import Fernet
print('WEBHOOK_SECRET='+secrets.token_urlsafe(32))
print('KEY_PEPPER='+secrets.token_urlsafe(48))
print('KEY_ENCRYPTION_KEY='+Fernet.generate_key().decode())
