"""Execute only generated adapters and one relocated prologue instruction in an isolated CPU emulator."""
import sys,json,struct
from pathlib import Path

from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as R
rows=json.loads(Path(__file__).with_name('client21-bridges.json').read_text())
from patch_client21 import relocate,branch
client=bytearray(0x4000)
for r in rows:
    code=bytes.fromhex(r['code']);symbol=r['export'].encode()+b'\0'
    client[r['bridge']:r['bridge']+len(code)]=code
    client[r['symbol']:r['symbol']+len(symbol)]=symbol
    word=struct.unpack('<I',bytes.fromhex(r['original'])[:4])[0]
    client[r['trampoline']:r['trampoline']+8]=struct.pack('<I',relocate(word,r['entry'],r['trampoline']))+branch(r['trampoline']+4,r['entry']+4)
BASE=0x10000000;STACK=0x30000000;CALLBACK=0x20000000
X=[getattr(R,f'UC_ARM64_REG_X{i}') for i in range(31)]
Q=[getattr(R,f'UC_ARM64_REG_Q{i}') for i in range(32)]
def setup(row,overridden):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM);u.mem_map(BASE,0x4000);u.mem_map(STACK,0x10000)
    u.mem_map((BASE+row['entry'])&~4095,0x2000);u.mem_map((BASE+0x12556d8)&~4095,0x1000);u.mem_map(CALLBACK,0x1000)
    u.mem_write(BASE,bytes(client[:0x4000]));u.mem_write(BASE+row['entry'],bytes.fromhex(row['original']))
    u.reg_write(R.UC_ARM64_REG_CPACR_EL1,3<<20)
    for i,r in enumerate(X):u.reg_write(r,0x100100000+i*0x100)
    for i,r in enumerate(Q):u.reg_write(r,((i+1)<<96)|((i+1)<<64)|((i+1)<<32)|(i+1))
    u.reg_write(R.UC_ARM64_REG_SP,STACK+0x8000);u.reg_write(R.UC_ARM64_REG_NZCV,0xa0000000)
    u.reg_write(X[0],10);u.reg_write(X[1],30)
    u.reg_write(R.UC_ARM64_REG_S0,struct.unpack('<I',struct.pack('<f',70))[0])
    if overridden:
        if row['name']=='FOV':u.reg_write(R.UC_ARM64_REG_S0,struct.unpack('<I',struct.pack('<f',90))[0])
        elif row['name']=='Clock':u.reg_write(X[0],23);u.reg_write(X[1],59)
        elif row['name']=='Weather':u.reg_write(X[0],9)
        else:u.reg_write(X[0],0x12345678)
    return u
def snapshot(u):return ([u.reg_read(x) for x in X],[u.reg_read(x) for x in Q],u.reg_read(R.UC_ARM64_REG_SP),u.reg_read(R.UC_ARM64_REG_NZCV))

STOP=0x20000800
for row in [rows[3]]+rows[9:]:
 for mode in ('fallback','pass','changed'):
  u=setup(row,False);u.reg_write(X[30],STOP);before=snapshot(u);arguments=[]
  def hook(cpu,address,size,user):
   if address in (BASE+row['entry']+4,STOP):cpu.emu_stop();return
   if address not in (BASE+0x12556d8,CALLBACK):return
   lr=cpu.reg_read(X[30])
   if address==BASE+0x12556d8:assert bytes(cpu.mem_read(cpu.reg_read(X[1]),len(row['export'])+1))==row['export'].encode()+b'\0'
   else:arguments.append([cpu.reg_read(x) for x in X[:8]])
   for i,r in enumerate(X[:18] if row['name']=='Logo' else X[:30]):cpu.reg_write(r,0xdead0000+i)
   for i,r in enumerate(Q):cpu.reg_write(r,(0xdead+i)<<64)
   cpu.reg_write(R.UC_ARM64_REG_NZCV,0x50000000)
   value=CALLBACK if address==BASE+0x12556d8 and mode!='fallback' else 0
   if address==CALLBACK:value=(1 if mode=='pass' else 0) if row['kind']=='gate' else 7
   cpu.reg_write(X[0],value);cpu.reg_write(R.UC_ARM64_REG_PC,lr)
  u.hook_add(UC_HOOK_CODE,hook);u.emu_start(BASE+row['bridge'],STOP,count=2000)
  if mode!='fallback':
   if row['kind']=='wrapper':assert arguments[0][row['args']]==BASE+row['trampoline']
   else:assert arguments[0][7]==STOP
  if mode=='changed' and row['kind']=='gate':expected=before;expected[0][0]=0
  elif mode!='fallback' and row['kind']=='wrapper':expected=before;expected[0][0]=7
  else:
   baseline=setup(row,False);baseline.reg_write(X[30],STOP);baseline.emu_start(BASE+row['entry'],BASE+row['entry']+4,count=1);expected=snapshot(baseline)
  assert snapshot(u)==expected,(row['name'],mode)
  print(row['name'],mode,'arguments/registers/stack/flags passed')
