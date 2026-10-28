"""Run production getLocal against a sparse memory fixture; no game code executes."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'Inject/PlayerSnapshot.mm').read_text()
production=source[source.index('bool anchors(uint64_t base)'):source.index('bool sameLocal(const Local &s)')]
fixture=r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <unordered_map>
struct V3 {float x,y,z;};
bool finite(V3 v){return std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z);}
struct Local {uint64_t base=0,pool=0,local=0,ped=0,vehicle=0;uint16_t id=0;V3 position{},velocity{};};
std::unordered_map<uint64_t,uint8_t> memory;
constexpr uint64_t base=0x100000000,pool=0x200000000,local=0x300000000,ped=0x400000000,car=0x500000000;
uint64_t imageBase(){return base;}
template<class T> bool read(uint64_t a,T &v){
 for(size_t i=0;i<sizeof(T);++i)if(!memory.count(a+i))return false;
 for(size_t i=0;i<sizeof(T);++i){reinterpret_cast<uint8_t *>(&v)[i]=memory[a+i];}
 return true;
}
template<class T> void put(uint64_t a,const T &v){for(size_t i=0;i<sizeof(T);++i)memory[a+i]=reinterpret_cast<const uint8_t *>(&v)[i];}
'''
test=r'''
int main(){
 put(base+0x92d4c8,uint32_t(0xf9401c00));put(base+0x9aabe8,uint32_t(0x2d07266a));put(base+0x15349c,uint32_t(0xfd00c260));put(base+0xf94e8,uint32_t(0x39552109));
 put(base+0x340de18,pool);put(pool,local);put(local,uint16_t(17));put(local+0x38,ped);
 put(ped+0x38,V3{1,2,3});put(ped+0x180,V3{0,0,0});put(ped+0x540,uint64_t(0));put(ped+0x548,uint8_t(0));
 Local s;assert(getLocal(s)&&s.vehicle==0);
 for(int i=0;i<100;++i){
  put(ped+0x540,car);put(ped+0x548,uint8_t(1));assert(getLocal(s)&&s.vehicle==car);
  // This is the reported regression: exiting clears the flag but preserves +540.
  put(ped+0x548,uint8_t(0));assert(getLocal(s)&&s.vehicle==0);
  uint64_t retained=0;assert(read(ped+0x540,retained)&&retained==car); // reader never mutates the native reference
 }
 put(ped+0x548,uint8_t(2));assert(getLocal(s)&&s.vehicle==0); // match native exact comparison
 memory.erase(ped+0x548);assert(!getLocal(s)&&s.vehicle==0); // unknown state never treated as on foot
 put(ped+0x548,uint8_t(0));put(base+0xf94e8,uint32_t(0));assert(!getLocal(s)); // incompatible layout rejected
 std::cout<<"Production vehicle entry/exit/stale-reference/unknown-state checks passed\n";
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp=Path(directory)/'vehicle.cpp';exe=Path(directory)/'vehicle';cpp.write_text(fixture+production+test)
    subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
