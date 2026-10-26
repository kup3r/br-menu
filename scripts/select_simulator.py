import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text())
for runtime, devices in sorted(payload['devices'].items(), reverse=True):
    if not runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
        continue
    for device in devices:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            print('BRMENU_SIMULATOR_ID=' + device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator with iOS runtime found.')
