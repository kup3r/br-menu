"""Build-time public endpoint configuration, never Telegram/server secrets."""
import json, os, sys
from pathlib import Path
from urllib.parse import urlparse

def configuration(environ):
    result=[]
    for name in ['BRMENU_LICENSE_API_URL','BRMENU_LICENSE_BOT_URL']:
        value=environ.get(name,'').strip().rstrip('/')
        url=urlparse(value)
        if url.scheme!='https' or not url.netloc or url.username or url.password or url.query or url.fragment:
            raise ValueError(f'{name}: supply a public HTTPS URL without credentials/query/fragment')
        result.append(value)
    return 'enum BRLicenseConfiguration {\n    static let apiURL = '+json.dumps(result[0],ensure_ascii=False)+'\n    static let botURL = '+json.dumps(result[1],ensure_ascii=False)+'\n}\n'

if __name__=='__main__':
    Path(sys.argv[1]).write_text(configuration(os.environ))
