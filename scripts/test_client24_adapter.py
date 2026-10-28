"""Emulate only the isolated default-pass adapter, never game instructions."""
import json
from pathlib import Path
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn import arm64_const as R
row=json.loads(Path(__file__).with_name('client24-water.json').read_text())
BASE=0x10000000;STACK=0x30000000;CALLBACK=0x20000000;STOP=CALLBACK+0x800
X=[getattr(R,f'UC_ARM64_REG_X{i}') for i in range(31)]
Q=[getattr(R,f'UC_ARM64_REG_Q{i}') for i in range(32)]
def snapshot(u):return ([u.reg_read(r) for r in X],[u.reg_read(r) for r in Q],u.reg_read(R.UC_ARM64_REG_SP),u.reg_read(R.UC_ARM64_REG_NZCV))
for mode in ('fallback','pass','skip'):
    u=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
    for address,size in [(BASE+row['vmaddr'],row['size']),(STACK,0x10000),(CALLBACK,0x1000),((BASE+0x12556d8)&~4095,4096),((BASE+row['original'])&~4095,4096)]:u.mem_map(address,size)
    u.mem_write(BASE+row['entry'],bytes.fromhex(row['code']));u.mem_write(BASE+row['symbol'],row['export'].encode()+b'\0')
    u.reg_write(R.UC_ARM64_REG_CPACR_EL1,3<<20)
    for i,r in enumerate(X):u.reg_write(r,0x12340000+i*0x100)
    for i,r in enumerate(Q):u.reg_write(r,((i+1)<<96)|((i+2)<<64)|((i+3)<<32)|(i+4))
    u.reg_write(X[30],STOP);u.reg_write(R.UC_ARM64_REG_SP,STACK+0x8000);u.reg_write(R.UC_ARM64_REG_NZCV,0xa0000000)
    before=snapshot(u);calls=[];dest=[]
    def hook(cpu,address,size,user):
        if address in (BASE+row['original'],STOP):dest.append(address);cpu.emu_stop();return
        if address not in (BASE+0x12556d8,CALLBACK):return
        lr=cpu.reg_read(X[30])
        if address==BASE+0x12556d8:assert bytes(cpu.mem_read(cpu.reg_read(X[1]),len(row['export'])+1))==row['export'].encode()+b'\0'
        else:calls.append(cpu.reg_read(X[0]));assert calls[-1]==before[0][0]
        for i,r in enumerate(X[:30]):cpu.reg_write(r,0xdead0000+i)
        for i,r in enumerate(Q):cpu.reg_write(r,(0xdead+i)<<64)
        cpu.reg_write(R.UC_ARM64_REG_NZCV,0x50000000)
        value=(0 if mode=='fallback' else CALLBACK) if address!=CALLBACK else (1 if mode=='pass' else 0)
        cpu.reg_write(X[0],value);cpu.reg_write(R.UC_ARM64_REG_PC,lr)
    u.hook_add(UC_HOOK_CODE,hook);u.emu_start(BASE+row['entry'],STOP+4,count=2000)
    expected=before
    if mode=='skip':expected[0][0]=0
    assert snapshot(u)==expected,mode
    assert dest==[STOP if mode=='skip' else BASE+row['original']],(mode,dest)
    print('Water adapter',mode,'registers, stack, flags and destination passed')
