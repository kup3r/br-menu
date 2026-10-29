"""Exercise production render rollback, water scoping and damage restoration.

UIKit context queries are replaced with booleans; GL and memory are synthetic.
No game binary, game function body or network connection is executed.
"""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
chams=(root/'Inject/Chams24.inc').read_text().split('void tickChams24()')[0]
water=(root/'Inject/Water24.inc').read_text()
damage=(root/'Inject/Damage24.inc').read_text()
def context(s):return s.replace('![NSThread isMainThread]','!onMain').replace('![EAGLContext currentContext]','!contextReady')
fixture=r'''
#include <array>
#include <atomic>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <mutex>
#include <unordered_map>
#include <vector>
bool onMain=true,contextReady=true,connected=true;
std::unordered_map<uint64_t,uint8_t> memory;uint64_t failWrite=0;
template<class T> bool read(uint64_t a,T &v){for(size_t i=0;i<sizeof(T);++i)if(!memory.count(a+i))return false;for(size_t i=0;i<sizeof(T);++i){reinterpret_cast<uint8_t *>(&v)[i]=memory[a+i];}return true;}
bool copy(uint64_t a,void *p,size_t n){for(size_t i=0;i<n;++i)if(!memory.count(a+i))return false;for(size_t i=0;i<n;++i){reinterpret_cast<uint8_t *>(p)[i]=memory[a+i];}return true;}
template<class T> bool writeData(uint64_t a,const T &v){if(a==failWrite){failWrite=0;return false;}for(size_t i=0;i<sizeof(T);++i)memory[a+i]=reinterpret_cast<const uint8_t *>(&v)[i];return true;}
template<class T> T value(uint64_t a){T v{};assert(read(a,v));return v;}
struct V3 {float x=0,y=0,z=0;};
struct Local {uint64_t base=0,pool=0,local=0,ped=0,vehicle=0;uint16_t id=0;V3 position{};};
Local own;bool liveConnected(Local &s){s=own;return connected;}
bool anchorAt(uint64_t base,uint64_t offset,uint32_t word){uint32_t v=0;return read(base+offset,v)&&v==word;}
namespace BRAim {bool living(double hp,double physicalHP,unsigned state){return std::isfinite(hp)&&std::isfinite(physicalHP)&&hp>0&&physicalHP>0&&state!=52&&state!=53;}}
uint64_t definition=0;uint64_t weaponDefinition(uint64_t base,uint8_t id){return base==own.base&&id==24?definition:0;}
std::atomic<uint64_t> verifiedProjectionBase{0};
using GLboolean=uint8_t;constexpr unsigned GL_DEPTH_TEST=1,GL_DEPTH_WRITEMASK=2;constexpr GLboolean GL_TRUE=1,GL_FALSE=0;
GLboolean depthTest=1,depthWrite=1;
GLboolean glIsEnabled(unsigned){return depthTest;}void glGetBooleanv(unsigned,GLboolean *v){*v=depthWrite;}
void glDisable(unsigned){depthTest=0;}void glEnable(unsigned){depthTest=1;}void glDepthMask(GLboolean v){depthWrite=v;}
uint64_t task=0x900000,brain=0x910000;
void *fakeFind(void *p){assert(reinterpret_cast<uint64_t>(p)==brain);return reinterpret_cast<void *>(task);}
uint64_t mat=0x810000,geometry=0x820000;int drawCount=0;bool expectTint=false;
void originalDraw(void *p,uint64_t flags){
 assert(reinterpret_cast<uint64_t>(p)==0x830000&&flags==0x1234);++drawCount;
 assert(value<uint64_t>(mat)==(expectTint?0:0x123400));
 assert(value<uint32_t>(mat+8)==(expectTint?0xff123456:0xffabcdef));
 if(expectTint){assert(depthTest==0&&depthWrite==0);auto f=value<uint32_t>(geometry+0x10);assert((f&0x60)==0x40);writeData(geometry+0x10,f|0x1000U);}
}
'''
test=r'''
int main(){
 own={reinterpret_cast<uint64_t>(&fakeFind)-0xa867d8,0x840000,0x850000,0x860000,0,1,{}};verifiedProjectionBase.store(own.base);
 const uint64_t remote=0x870000,ped=0x880000,clump=0x890000,atomic=0x830000,materials=0x8a0000;
 writeData(own.base+0x340de18,own.pool);writeData(own.pool+8+2*8,remote);writeData(remote+0x10,ped);writeData(ped+0x68,clump);
 writeData(atomic+0x50,clump);writeData(atomic+0x28,geometry);writeData(atomic+0x70,chamsCallback24());
 writeData(geometry+0x10,uint32_t(0x22));writeData(geometry+0x80,materials);writeData(geometry+0x88,int32_t(2));
 std::array<uint64_t,2> pointers{mat,mat};writeData(materials,pointers);writeData(mat,uint64_t(0x123400));writeData(mat+8,uint32_t(0xffabcdef));
 const std::array<float,3> surface{.7f,.2f,.8f};writeData(mat+12,surface);
 chamsRecords24[atomic]={own.base,own.pool,remote,ped,clump,atomic,geometry,reinterpret_cast<uint64_t>(&originalDraw),2,1,true};
 chamsColor24.store(0xff123456);chamsEnabled24.store(true);expectTint=true;renderChams24(reinterpret_cast<void *>(atomic),0x1234);
 assert(drawCount==1&&depthTest==1&&depthWrite==1);assert(value<uint32_t>(geometry+0x10)==0x1022);
 assert((value<uint64_t>(mat)==0x123400&&value<uint32_t>(mat+8)==0xffabcdef&&value<std::array<float,3>>(mat+12)==surface));
 // A mid-update failure restores all prior changes before calling the original renderer.
 expectTint=false;failWrite=mat+8;renderChams24(reinterpret_cast<void *>(atomic),0x1234);
 assert(drawCount==2&&value<uint64_t>(mat)==0x123400&&value<uint32_t>(mat+8)==0xffabcdef);
 contextReady=false;renderChams24(reinterpret_cast<void *>(atomic),0x1234);assert(drawCount==3);contextReady=true;
 // Stream-out/reuse never writes an old function pointer into a new owner's object.
 writeData(remote+0x10,uint64_t(0xdead000));stopChams24();assert(value<uint64_t>(atomic+0x70)==chamsCallback24());assert(!chamsRecords24.at(atomic).active);
 renderChams24(reinterpret_cast<void *>(atomic),0x1234);assert(drawCount==4);
 writeData(remote+0x10,ped);stopChams24();assert(chamsRecords24.empty());assert(value<uint64_t>(atomic+0x70)==reinterpret_cast<uint64_t>(&originalDraw));
 // Water gate affects only the verified, connected, living on-foot owner.
 writeData(own.base+0x99a54c,uint32_t(0xd10183ff));writeData(own.base+0xa867d8,uint32_t(0xf9400801));
 writeData(own.ped+0x8c,uint32_t(0x04000001));writeData(own.ped+0x798,brain);writeData(task+0x68,0.f);
 waterWalk24.store(true);assert(waterDecision24(own.ped)==0);assert(value<uint32_t>(own.ped+0x8c)==1&&value<float>(task+0x68)==1000);
 writeData(own.ped+0x8c,uint32_t(0x04000001));assert(waterDecision24(ped)==1);assert(value<uint32_t>(own.ped+0x8c)==0x04000001);
 own.vehicle=1;assert(waterDecision24(own.ped)==1);own.vehicle=0;connected=false;assert(waterDecision24(own.ped)==1);connected=true;
 waterWalk24.store(false);assert(waterDecision24(own.ped)==1);
 // Scoped damage does not accumulate, touch unrelated shots or overwrite a new definition.
 const uint64_t gun=0x920000;definition=0x930000;writeData(gun,uint8_t(24));writeData(ped+0x78,uint8_t(3));writeData(ped+0x4b0,100.f);writeData(ped+0x494,uint32_t(0));
 writeData(own.base+0xb0f558,uint32_t(0xbd403ae0));writeData(definition+0x38,uint32_t(25));damageFactor24.store(3);
 {DamageScope24 a(reinterpret_cast<void *>(own.ped),reinterpret_cast<void *>(ped),reinterpret_cast<void *>(gun));assert(value<uint32_t>(definition+0x38)==75);
  {DamageScope24 nested(reinterpret_cast<void *>(own.ped),reinterpret_cast<void *>(ped),reinterpret_cast<void *>(gun));assert(value<uint32_t>(definition+0x38)==75);}}
 assert(value<uint32_t>(definition+0x38)==25&&!DamageScope24::busy);
 {DamageScope24 other(reinterpret_cast<void *>(ped),reinterpret_cast<void *>(own.ped),reinterpret_cast<void *>(gun));assert(value<uint32_t>(definition+0x38)==25);}
 {DamageScope24 changed(reinterpret_cast<void *>(own.ped),reinterpret_cast<void *>(ped),reinterpret_cast<void *>(gun));writeData(definition+0x38,uint32_t(40));}assert(value<uint32_t>(definition+0x38)==40);
 writeData(ped+0x494,uint32_t(53));{DamageScope24 dead(reinterpret_cast<void *>(own.ped),reinterpret_cast<void *>(ped),reinterpret_cast<void *>(gun));assert(value<uint32_t>(definition+0x38)==40);}
 std::cout<<"Production chams rollback/stream-out, water owner scoping and scoped damage checks passed\n";
}
'''
with tempfile.TemporaryDirectory() as directory:
    p=Path(directory);cpp=p/'visual.cpp';exe=p/'visual';cpp.write_text(fixture+context(chams)+context(water)+context(damage)+test)
    subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(cpp),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
