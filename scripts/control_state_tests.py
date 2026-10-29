"""Exercise production backup/restore code against a sparse synthetic address space.
No game binary is executed. Uses the exact functions compiled into PlayerSnapshot.
"""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'Inject/PlayerSnapshot.mm').read_text()
functions=source[source.index('struct SpreadBackup'):source.index('bool hasWeaponSlot')]
pre=r'''
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cassert>
#include <iostream>
std::unordered_map<uint64_t,uint8_t> memory;
template<class T> bool read(uint64_t address,T &v) {for(size_t i=0;i<sizeof(T);++i)if(!memory.count(address+i))return false;for(size_t i=0;i<sizeof(T);++i)reinterpret_cast<uint8_t *>(&v)[i]=memory[address+i];return true;}
template<class T> bool writeData(uint64_t address,const T &v) {for(size_t i=0;i<sizeof(T);++i)memory[address+i]=reinterpret_cast<const uint8_t *>(&v)[i];return true;}
template<class T> T value(uint64_t a){T v{};assert(read(a,v));return v;}
struct Local {uint64_t base=0,ped=0,local=0;uint16_t id=0;};
struct Weapon {uint64_t info=0;uint8_t id=0;int state=0,clip=1;};
struct {bool noSpread=false,noAnim=false,fastAnim=false,rapid=false;double animationRate=2,fireRate=3;} assists;
Weapon currentWeapon; bool valid=true,weaponValid=true;uint64_t definition=0;
bool sameLocal(const Local &){return valid;}
bool getWeapon(const Local &,Weapon &w){w=currentWeapon;return weaponValid;}
bool sameWeapon(const Local &,const Weapon &){return valid;}
uint64_t weaponDefinition(uint64_t,uint8_t){return definition;}
'''
test=r'''
int main(){
 Local s{0x100000,0x200000,0x300000,7};
 currentWeapon={0x400000,24};definition=currentWeapon.info;
 std::array<float,3> axes{.2f,.4f,.6f};writeData(definition+0x44,axes);
 assists.noSpread=true;updateSpread(s);assert(value<float>(definition+0x44)==0);
 // Native updates while enabled become the restoration baseline.
 writeData(definition+0x48,.8f);updateSpread(s);assists.noSpread=false;updateSpread(s);
 assert(value<float>(definition+0x44)==.2f&&value<float>(definition+0x48)==.8f);
 assists.noSpread=true;updateSpread(s);definition=0x410000;restoreSpread();
 assert(!spreadBackup.info);assert(value<float>(0x400044)==0); // stale registry is never written
 uint64_t clump=0x500000,data=0x600000,node=0x700000;
 writeData(s.ped+0x68,clump);writeData(clump,uint8_t(2));writeData(s.base+0x2118bc0,int32_t(0x100));
 writeData(clump+0x100,data);writeData(data,node);writeData(node,uint64_t(0));
 writeData(node+0x20,uint64_t(0x800000));writeData(node+0x40,int16_t(17));writeData(node+0x42,uint16_t(0x21));writeData(node+0x34,1.f);writeData(s.ped+0x4b0,100.f);
 assists.fastAnim=true;updateAnimations(s);assert(value<float>(node+0x34)==2);
 updateAnimations(s);assert(value<float>(node+0x34)==2); // no multiplier accumulation
 assists.noAnim=true;updateAnimations(s);assert(value<float>(node+0x34)==0);assert(value<uint16_t>(node+0x42)==0x20);
 assists.noAnim=false;assists.fastAnim=false;updateAnimations(s);assert(value<float>(node+0x34)==1);assert(value<uint16_t>(node+0x42)==0x21);
 assists.fastAnim=true;updateAnimations(s);writeData(node+0x34,.5f);updateAnimations(s);
 assert(value<float>(node+0x34)==1);assists.fastAnim=false;updateAnimations(s);assert(value<float>(node+0x34)==.5f);
 assists.noAnim=true;updateAnimations(s);writeData(s.ped+0x4b0,0.f);updateAnimations(s);
 assert(value<float>(node+0x34)==.5f); // death releases pause
 assists.noAnim=false;writeData(node,node);updateAnimations(s); // cyclic list terminates
 writeData(s.ped+0x4b0,100.f);writeData(node,uint64_t(0));writeData(node+0x40,int16_t(0xf8));writeData(node+0x34,1.f);
 assists.rapid=true;updateAnimations(s);assert(value<float>(node+0x34)==3);
 updateAnimations(s);assert(value<float>(node+0x34)==3); // no accumulation
 currentWeapon.state=2;updateAnimations(s);assert(value<float>(node+0x34)==1); // reload is not accelerated
 currentWeapon.state=0;assists.rapid=false;
 std::cout<<"Production control backup/restore tests passed\n";
}
'''
with tempfile.TemporaryDirectory() as directory:
 cpp=Path(directory)/'controls.cpp';binary=Path(directory)/'controls';cpp.write_text(pre+functions+test)
 subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(cpp),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

