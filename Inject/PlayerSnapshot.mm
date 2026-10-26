#import "PlayerSnapshot.h"
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <array>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <cstdint>
#include <stdlib.h>
#include <dlfcn.h>
#include <atomic>
#include <mutex>
#include <unordered_set>
#include <string>
#include <vector>
#include "AimMath.hpp"

namespace {
// Static evidence applies only to this exact blackrussia-client build.
constexpr uint8_t expectedUUID[16] = {0x85,0x58,0x46,0xc3,0x4f,0x72,0x37,0x70,0xb8,0x11,0xdd,0x7f,0xbe,0x68,0xb0,0xdb};
std::atomic<uint64_t> verifiedProjectionBase{0};
NSString *lastStatus = @"Ожидание модуля клиента";
std::mutex statusMutex,collectorMutex;
void setStatus(NSString *value) {std::lock_guard<std::mutex> lock(statusMutex);lastStatus=value;}
struct V3 { float x,y,z; };
struct Matrix { float v[16]; };
bool copy(uint64_t address, void *destination, size_t bytes) {
    if (address < 0x10000 || address > UINT64_MAX - bytes) return false;
    static_assert(sizeof(vm_address_t) == sizeof(uint64_t), "ESP reader requires a 64-bit target");
    vm_size_t actual = 0;
    return vm_read_overwrite(mach_task_self(), static_cast<vm_address_t>(address), static_cast<vm_size_t>(bytes),
        reinterpret_cast<vm_address_t>(destination), &actual) == KERN_SUCCESS && actual == bytes;
}
template<class T> bool read(uint64_t address, T &value) { return copy(address, &value, sizeof(value)); }
template<class T> T field(const uint8_t *data, size_t offset) { T v{}; std::memcpy(&v, data+offset, sizeof(v)); return v; }
uint64_t imageBase() {
    for (uint32_t i=0;i<_dyld_image_count();++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !std::strstr(name,"blackrussia-client.framework/blackrussia-client")) continue;
        const mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return 0;
        const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header)+sizeof(mach_header_64);
        const uint8_t *end = cursor+header->sizeofcmds;
        for (uint32_t j=0;j<header->ncmds && cursor+sizeof(load_command)<=end;++j) {
            const auto *cmd=reinterpret_cast<const load_command *>(cursor);
            if (cmd->cmdsize<sizeof(load_command) || cursor+cmd->cmdsize>end) break;
            if (cmd->cmd==LC_UUID && cmd->cmdsize>=sizeof(uuid_command)) {
                const auto *uuid=reinterpret_cast<const uuid_command *>(cursor);
                if (std::memcmp(uuid->uuid,expectedUUID,16)!=0) {
                    setStatus(@"ESP отключён: UUID клиента не совпадает"); return 0;
                }
                verifiedProjectionBase.store(reinterpret_cast<uint64_t>(header),std::memory_order_release);
                return reinterpret_cast<uint64_t>(header);
            }
            cursor+=cmd->cmdsize;
        }
        setStatus(@"ESP отключён: UUID недоступен"); return 0;
    }
    verifiedProjectionBase.store(0,std::memory_order_release);
    setStatus(@"Ожидание blackrussia-client"); return 0;
}
bool finite(V3 p) { return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z)&&std::abs(p.x)<100000&&std::abs(p.y)<100000&&std::abs(p.z)<100000; }
bool project(const Matrix &m, V3 p, float &x, float &y) {
    if (!finite(p)) return false;
    float tx=m.v[0]*p.x+m.v[4]*p.y+m.v[8]*p.z+m.v[12];
    float ty=m.v[1]*p.x+m.v[5]*p.y+m.v[9]*p.z+m.v[13];
    float tz=m.v[2]*p.x+m.v[6]*p.y+m.v[10]*p.z+m.v[14];
    if (!std::isfinite(tz)||tz<=0.05f) return false;
    x=tx/tz;y=ty/tz;
    return std::isfinite(x)&&std::isfinite(y)&&x>-4&&x<5&&y>-4&&y<5;
}
// Verified independently from the local-player getters and Physical.cpp's
// impulse routine. No writes to executable pages or protection changes.
struct Flight { bool active=false; uint64_t ped=0,local=0; V3 point{}; double speed=5; V3 input{}; };
Flight flight;
struct Assists {
    bool health=false,armor=false,stamina=false,vehicleHealth=false,slowFall=false;
    bool noClip=false,proof=false,noFall=false,vehicleProof=false,ammo=false,magazine=false,rapid=false;
    bool noCollision=false,noSpread=false,noAnim=false,fastAnim=false;
    double fireRate=2,animationRate=2;
};
Assists assists;
struct Local { uint64_t base=0,pool=0,local=0,ped=0,vehicle=0; uint16_t id=0; V3 position{},velocity{}; };
bool anchors(uint64_t base) {
    uint32_t getter=0,position=0,velocity=0;
    return read(base+0x92d4c8,getter)&&getter==0xf9401c00U&&
        read(base+0x9aabe8,position)&&position==0x2d07266aU&&
        read(base+0x15349c,velocity)&&velocity==0xfd00c260U;
}
bool getLocal(Local &s) {
    s.base=imageBase();
    if(!s.base||!anchors(s.base))return false;
    return read(s.base+0x340de18,s.pool)&&s.pool&&read(s.pool,s.local)&&s.local&&
        read(s.local,s.id)&&s.id<1504&&read(s.local+0x38,s.ped)&&s.ped&&
        read(s.ped+0x38,s.position)&&finite(s.position)&&
        read(s.ped+0x180,s.velocity)&&finite(s.velocity)&&read(s.ped+0x540,s.vehicle);
}
bool sameLocal(const Local &s) {
    uint64_t pool=0,local=0,ped=0;uint16_t id=0;
    return read(s.base+0x340de18,pool)&&pool==s.pool&&read(pool,local)&&local==s.local&&
        read(local,id)&&id==s.id&&read(local+0x38,ped)&&ped==s.ped;
}
template<class T> bool writeData(uint64_t address,const T &value) {
    T before{};if(!read(address,before))return false;
    return vm_write(mach_task_self(),static_cast<vm_address_t>(address),
        reinterpret_cast<vm_offset_t>(&value),static_cast<mach_msg_type_number_t>(sizeof(T)))==KERN_SUCCESS;
}
struct MassBackup { uint64_t entity=0,ped=0,local=0;float original=0;uint16_t id=0; };
MassBackup pedMass,vehicleMass;
bool restoreMass(const Local &s,MassBackup &backup,uint64_t entity) {
    const MassBackup old=backup;
    if(!old.entity)return true;
    if(old.entity!=entity||old.ped!=s.ped||old.local!=s.local||old.id!=s.id||!sameLocal(s)) {backup={};return false;}
    if(!writeData(entity+0x1c8,old.original))return false;
    backup={};return true;
}
bool destination(V3 p) {
    return finite(p)&&std::abs(p.x)<=20000&&std::abs(p.y)<=20000&&p.z>=-500&&p.z<=5000;
}
NSString *teleport(const Local &s,V3 p) {
    if(s.vehicle)return @"Для телепорта выйди из транспорта";
    if(!destination(p))return @"Координаты вне допустимых границ";
    uint64_t task=0;
    // The native routine touches the ped task manager; do not call while loading.
    if(!read(s.ped+0x798,task)||!task||!sameLocal(s))return @"Персонаж ещё не готов";
    const std::array<uint8_t,16> expected{0xeb,0x2b,0xbc,0x6d,0xe9,0x23,0x01,0x6d,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9};
    std::array<uint8_t,16> actual{};
    if(!copy(s.base+0x9aab84,actual.data(),actual.size())||actual!=expected)return @"Функция телепорта не прошла проверку";
    using Move=void(*)(void *,float,float,float);
    reinterpret_cast<Move>(s.base+0x9aab84)(reinterpret_cast<void *>(s.ped),p.x,p.y,p.z);
    return @"Локальная команда телепорта выполнена";
}

bool anchorAt(uint64_t base,uint64_t offset,uint32_t word) {uint32_t v=0;return read(base+offset,v)&&v==word;}
struct VehicleRef {uint64_t base=0,pool=0,net=0,vehicle=0;uint16_t id=0;uint32_t generation=0;};
bool vehicleRef(uint64_t base,uint64_t vehicle,VehicleRef &v) {
    v={};v.base=base;v.vehicle=vehicle;
    if(!vehicle||!anchorAt(base,0x972030,0xf8615800U))return false;
    uint64_t actual=0;
    return read(vehicle+0x434,v.id)&&v.id<2000&&read(vehicle+0x174,v.generation)&&
        read(base+0x340de20,v.pool)&&v.pool&&read(v.pool+uint64_t(v.id)*8,v.net)&&v.net&&read(v.net,actual)&&actual==vehicle;
}
bool liveVehicle(const VehicleRef &v) {
    uint64_t pool=0,net=0,vehicle=0;uint32_t generation=0;
    return v.vehicle&&read(v.base+0x340de20,pool)&&pool==v.pool&&read(pool+uint64_t(v.id)*8,net)&&net==v.net&&
        read(net,vehicle)&&vehicle==v.vehicle&&read(vehicle+0x174,generation)&&generation==v.generation;
}
struct Weapon {uint64_t brain=0,begin=0,end=0,address=0,info=0;uint8_t slot=0,id=0;int32_t state=0,clip=0,total=0;uint32_t capacity=0,next=0;};
bool getWeapon(const Local &s,Weapon &w) {
    if(!anchorAt(s.base,0x9d6400,0x39411008U)||!anchorAt(s.base,0xb0bb30,0xb9000a68U)||!anchorAt(s.base,0xb0bb40,0xb9000e68U))return false;
    if(!read(s.ped+0x5b0,w.brain)||!w.brain||!read(w.brain+0x44,w.slot)||w.slot==255||
       !read(w.brain+0x48,w.begin)||!read(w.brain+0x50,w.end)||w.end<w.begin||
       (w.end-w.begin)%32||(w.end-w.begin)/32>256||w.slot>=(w.end-w.begin)/32)return false;
    w.address=w.begin+uint64_t(w.slot)*32;
    std::array<uint8_t,32> data{};
    if(!copy(w.address,data.data(),data.size()))return false;
    w.id=data[0];w.state=field<int32_t>(data.data(),4);w.clip=field<int32_t>(data.data(),8);w.total=field<int32_t>(data.data(),12);w.next=field<uint32_t>(data.data(),16);
    if(w.id==0||w.id==255||w.state<0||w.state>5||w.clip<0||w.total<0||w.clip>100000||w.total>100000)return false;
    uint64_t table=0,count=0,node=0;
    if(!read(s.base+0x3537cb8,table)||!read(s.base+0x3537cc0,count)||!table||count<1||count>65536||!read(table+(w.id%count)*8,node))return false;
    for(int i=0;i<128&&node;++i) {
        uint8_t id=0;if(!read(node,id))return false;
        if(id==w.id) {w.info=node+8;break;}
        uint64_t next=0;if(!read(node+0x210,next)||next==node)return false;node=next;
    }
    uint32_t fire=0;
    return w.info&&read(w.info+0x20,fire)&&fire==1&&read(w.info+0x34,w.capacity)&&w.capacity>=1&&w.capacity<=1000;
}
bool sameWeapon(const Local &s,const Weapon &w) {
    uint64_t brain=0,begin=0,end=0;uint8_t slot=0,id=0;
    return sameLocal(s)&&read(s.ped+0x5b0,brain)&&brain==w.brain&&read(brain+0x44,slot)&&slot==w.slot&&
        read(brain+0x48,begin)&&begin==w.begin&&read(brain+0x50,end)&&end==w.end&&read(w.address,id)&&id==w.id;
}
struct PedFlagBackup {uint64_t ped=0,local=0;uint16_t id=0;std::array<uint8_t,3> original{};};
PedFlagBackup pedFlags;
void updatePedFlags(const Local &s) {
    if(pedFlags.ped&&(pedFlags.ped!=s.ped||pedFlags.local!=s.local||pedFlags.id!=s.id))pedFlags={};
    bool collision=assists.noCollision||(assists.noClip&&flight.active);
    float hp=0;const bool alive=read(s.ped+0x4b0,hp)&&std::isfinite(hp)&&hp>0;
    bool protection=assists.proof&&alive,fall=assists.noFall&&alive;
    if(!collision&&!protection&&!fall&&!pedFlags.ped)return;
    if(!anchorAt(s.base,0x15c4d0,0x39423029U)||!sameLocal(s))return;
    std::array<uint8_t,3> current{};if(!copy(s.ped+0x8c,current.data(),current.size()))return;
    if(!pedFlags.ped){pedFlags.ped=s.ped;pedFlags.local=s.local;pedFlags.id=s.id;pedFlags.original=current;}
    auto desired=current;
    desired[0]=uint8_t((current[0]&~1U)|(collision?0U:(pedFlags.original[0]&1U)));
    desired[1]=uint8_t((current[1]&~2U)|((protection||fall)?2U:(pedFlags.original[1]&2U)));
    desired[2]=uint8_t((current[2]&~0x3eU)|(protection?0x3eU:(pedFlags.original[2]&0x3eU)));
    if(desired!=current&&!writeData(s.ped+0x8c,desired))return;
    if(!collision&&!protection&&!fall)pedFlags={};
}
struct VehicleGuard {VehicleRef ref{};uint8_t original=0;bool active=false;};
VehicleGuard vehicleGuard;
void restoreVehicleGuard() {
    if(!vehicleGuard.active)return;
    if(liveVehicle(vehicleGuard.ref)) {
        uint8_t value=0;
        if(read(vehicleGuard.ref.vehicle+0x382,value)){value=uint8_t((value&~2U)|(vehicleGuard.original&2U));(void)writeData(vehicleGuard.ref.vehicle+0x382,value);}
    }
    vehicleGuard={};
}
void updateVehicleGuard(const Local &s) {
    if(vehicleGuard.active&&(!assists.vehicleProof||s.vehicle!=vehicleGuard.ref.vehicle||!liveVehicle(vehicleGuard.ref)))restoreVehicleGuard();
    if(!assists.vehicleProof||!s.vehicle)return;
    if(!anchorAt(s.base,0xafc084,0x394e0a88U))return;
    if(!vehicleGuard.active) {
        VehicleRef ref{};uint8_t value=0;
        if(!vehicleRef(s.base,s.vehicle,ref)||!read(s.vehicle+0x382,value))return;
        vehicleGuard={ref,value,true};
    }
    uint8_t value=0;
    if(liveVehicle(vehicleGuard.ref)&&read(s.vehicle+0x382,value)){value&=uint8_t(~2U);(void)writeData(s.vehicle+0x382,value);}
}
struct GravityBackup {uint64_t entity=0,ped=0,local=0;uint16_t id=0;float original=0;bool car=false;VehicleRef ref{};};
GravityBackup pedGravity,carGravity;
bool restoreGravity(const Local &s,GravityBackup &backup) {
    if(!backup.entity)return true;
    const bool valid=backup.car?liveVehicle(backup.ref):(backup.ped==s.ped&&backup.local==s.local&&backup.id==s.id&&sameLocal(s));
    if(!valid){backup={};return false;}
    if(!writeData(backup.entity+0x170,backup.original))return false;
    backup={};return true;
}
void weaponAssists(const Local &s) {
    if(!assists.ammo&&!assists.magazine&&!assists.rapid)return;
    Weapon w;if(!getWeapon(s,w)||!sameWeapon(s,w))return;
    int32_t total=w.total;
    if(assists.ammo&&total<999){total=999;(void)writeData(w.address+12,total);}
    if(assists.magazine&&total>0) {
        int32_t clip=std::min(total,int32_t(w.capacity));
        if(w.clip<clip)(void)writeData(w.address+8,clip);
        if(w.state==2&&clip>0){const int32_t ready=0;(void)writeData(w.address+4,ready);}
    }
    if(assists.rapid&&w.state==1) {
        static uint64_t lastWeapon=0;static uint32_t lastAdjusted=0;
        if(w.address==lastWeapon&&w.next==lastAdjusted)return;
        uint32_t now=0;if(!read(s.base+0x2f348e0,now))return;
        const int32_t remaining=int32_t(w.next-now);
        if(remaining>0&&remaining<60000) {
            const uint32_t next=now+uint32_t(double(remaining)/assists.fireRate);
            if(writeData(w.address+16,next)){lastWeapon=w.address;lastAdjusted=next;}
        }
    }
}

// Catalog (1024-pointer chunks) and streaming slots (512 x 96-byte chunks)
// are separate registries. Read both with the bounds/valid-bit rules from the client.
bool registeredBit(uint64_t base,uint64_t header,uint32_t id) {
    uint64_t begin=0,end=0,unused=0,word=0;
    if(!read(base+header,begin)||!read(base+header+8,end)||!read(base+header+24,unused)||end<begin||end-begin>0x200000||unused>64)return false;
    const uint64_t bits=(end-begin)*8;if(bits<unused||id>=bits-unused)return false;
    return read(begin+uint64_t(id/64)*8,word)&&((word>>(id%64))&1);
}
uint64_t modelCatalog(uint64_t base,uint32_t id,uint8_t expected=0) {
    if(id>1000000||!registeredBit(base,0x19b22a8,id))return 0;
    uint64_t chunks=0,chunk=0,info=0;uint8_t kind=0;
    if(!read(base+0x19b2290,chunks)||!chunks||!read(chunks+uint64_t(id/1024)*8,chunk)||!chunk||
       !read(chunk+uint64_t(id%1024)*8,info)||!info||!read(info+0x20,kind))return 0;
    return !expected||kind==expected?info:0;
}
uint64_t streamSlot(uint64_t base,uint32_t id) {
    if(id>1000000||!registeredBit(base,0x2ed3c30,id))return 0;
    uint64_t chunks=0,chunk=0;
    if(!read(base+0x2ed3c18,chunks)||!chunks||!read(chunks+uint64_t(id/512)*8,chunk)||!chunk)return 0;
    return chunk+uint64_t(id%512)*96;
}
uint64_t weaponDefinition(uint64_t base,uint8_t id) {
    uint64_t table=0,count=0,node=0;
    if(!id||id==255||!read(base+0x3537cb8,table)||!read(base+0x3537cc0,count)||!table||!count||count>65536||!read(table+(id%count)*8,node))return 0;
    for(int n=0;n<128&&node;++n) {
        uint8_t key=0;if(!read(node,key))return 0;
        if(key==id)return node+8;
        uint64_t next=0;if(!read(node+0x210,next)||next==node)return 0;node=next;
    }
    return 0;
}
// WeaponInfo axes are the random bullet dispersion amplitudes at b0bef0.
// Definitions are shared locally. Never restore through a stale registry node.
struct SpreadBackup {uint64_t base=0,info=0;uint8_t id=0;std::array<float,3> original{};};
SpreadBackup spreadBackup;
void restoreSpread() {
    if(spreadBackup.info&&weaponDefinition(spreadBackup.base,spreadBackup.id)==spreadBackup.info) {
        std::array<float,3> current{};
        if(read(spreadBackup.info+0x44,current))for(size_t i=0;i<3;++i)
            if(current[i]==0)(void)writeData(spreadBackup.info+0x44+i*4,spreadBackup.original[i]);
    }
    spreadBackup={};
}
void updateSpread(const Local &s) {
    Weapon w{};
    const bool active=assists.noSpread&&getWeapon(s,w)&&sameWeapon(s,w);
    if(spreadBackup.info&&(!active||spreadBackup.info!=w.info||spreadBackup.base!=s.base))restoreSpread();
    if(!active||!sameLocal(s))return;
    if(!spreadBackup.info) {
        std::array<float,3> values{};
        if(!read(w.info+0x44,values))return;
        for(float v:values)if(!std::isfinite(v)||std::abs(v)>100)return;
        spreadBackup={s.base,w.info,w.id,values};
    }
    std::array<float,3> current{};
    if(!read(w.info+0x44,current))return;
    for(size_t i=0;i<3;++i)if(current[i]!=0) {
        if(!std::isfinite(current[i])||std::abs(current[i])>100)return;
        spreadBackup.original[i]=current[i];
    }
    const std::array<float,3> zero{};(void)writeData(w.info+0x44,zero);
}
// RenderWare association speed (+34) is consumed by 5a34 and current time by 5a60.
// Pause/speed changes affect playback, not server tasks or animation permissions.
struct AnimationBackup {uint64_t association=0,hierarchy=0;int16_t id=0;float original=1,last=1;};
struct AnimationState {uint64_t ped=0,local=0,clump=0;uint16_t id=0;std::vector<AnimationBackup> entries;};
AnimationState animationState;
void updateAnimations(const Local &s) {
    uint64_t clump=0,data=0,node=0;int32_t offset=0;uint8_t type=0;float hp=0;
    if(!sameLocal(s)||!read(s.ped+0x68,clump)||!clump||!read(clump,type)||type!=2||
       !read(s.base+0x2118bc0,offset)||offset<0||offset>0x10000||!read(clump+offset,data)||!data||!read(data,node)||
       !read(s.ped+0x4b0,hp)||!std::isfinite(hp))return;
    if(animationState.ped!=s.ped||animationState.local!=s.local||animationState.id!=s.id||animationState.clump!=clump)animationState={};
    const bool enabled=hp>0&&(assists.noAnim||assists.fastAnim);
    std::vector<AnimationBackup> next;std::unordered_set<uint64_t> seen;
    for(int i=0;i<64&&node&&seen.insert(node).second;++i) {
        uint64_t link=0,hierarchy=0;int16_t id=0;float speed=0;
        if(!read(node,link)||!read(node+0x20,hierarchy)||!hierarchy||!read(node+0x40,id)||!read(node+0x34,speed)||
           !std::isfinite(speed)||speed<0||speed>32)break;
        auto found=std::find_if(animationState.entries.begin(),animationState.entries.end(),[&](const AnimationBackup &a){return a.association==node&&a.hierarchy==hierarchy&&a.id==id;});
        AnimationBackup entry{node,hierarchy,id,speed,speed};
        if(found!=animationState.entries.end()) {entry=*found;if(speed!=entry.last)entry.original=speed;}
        if(enabled) {
            const float desired=assists.noAnim?0.f:std::min(32.f,float(entry.original*assists.animationRate));
            if(writeData(node+0x34,desired)){entry.last=desired;next.push_back(entry);}
        } else if(found!=animationState.entries.end()&&speed==entry.last)(void)writeData(node+0x34,entry.original);
        node=link;
    }
    animationState={s.ped,s.local,clump,s.id,std::move(next)};
}
bool hasWeaponSlot(const Local &s,uint8_t weapon,uint64_t definition,uint64_t &brain) {
    uint64_t begin=0,end=0,config=0,configEnd=0;uint8_t initialized=0,byGroup=0;
    if(!read(s.ped+0x5b0,brain)||!brain||!read(brain+0x48,begin)||!read(brain+0x50,end)||end<begin||(end-begin)%32||(end-begin)/32>256||
       !read(s.base+0x1b2aec0,initialized)||!(initialized&1)||!read(s.base+0x1b2af20,config)||!read(s.base+0x1b2af28,configEnd)||
       configEnd<config||(configEnd-config)%12||(configEnd-config)/12>256||!read(s.base+0x1b2af39,byGroup))return false;
    uint32_t group=0;uint8_t category=0;
    if(!read(definition+0x168,group)||!read(definition+0x1e0,category))return false;
    for(uint64_t p=config;p<configEnd;p+=12) {
        std::array<uint8_t,12> row{};if(!copy(p,row.data(),row.size()))return false;
        if(row[0]>=(end-begin)/32)continue;
        if(byGroup==1?field<uint32_t>(row.data(),4)==group:row[1]==category)return true;
    }
    return false;
}
// Snapshot publication and UI target selection have their own short lock.
// The shot callback copies one selected actor, then revalidates it before use.
struct AimActor {
    uint64_t ped=0,remote=0;uint16_t id=0;V3 root{},offset{},head{};
    float hp=0,physicalHP=0;uint32_t state=0;std::array<char,128> nick{};
};
struct AimSettings {
    bool enabled=false,head=false;double miss=0;BRAim::View view{};
    std::array<bool,1504> excluded{};std::unordered_set<std::string> names;
};
std::mutex aimMutex;
uint64_t aimConfigGeneration=0;
AimSettings aimSettings;
std::array<AimActor,128> aimActors{};size_t aimCount=0;
double aimReceived=0;AimActor aimChosen{};bool aimHasChosen=false;
uint16_t aimOwnID=UINT16_MAX;float aimRange=0;V3 aimOwnPosition{};
std::atomic<bool> aimEnabled{false};
std::atomic<uint64_t> aimCallbacks{0},aimRedirects{0},aimSkipped{0};
bool aimBridgeReady(uint64_t base) {
    // Check the immutable bridge, trampoline and symbol name together.
    std::array<uint32_t,6> manifest{};std::array<uint8_t,20> trampoline{};
    constexpr std::array<uint8_t,16> original{0xf8,0x5f,0xbc,0xa9,0xf6,0x57,0x01,0xa9,0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9};
    std::array<char,18> symbol{};uint32_t entry=0;
    if(!base||!read(base+0x2300,manifest)||std::memcmp(manifest.data(),"BR15HOOK",8)!=0||manifest[2]!=1||
       manifest[3]!=0xb06a00||manifest[4]!=0x2000||manifest[5]!=0x2200||
       !read(base+0xb06a00,entry)||entry!=0x17d3ed80U||!read(base+0x2200,trampoline)||
       !std::equal(original.begin(),original.end(),trampoline.begin())||
       field<uint32_t>(trampoline.data(),16)!=0x142c1200U||
       !read(base+0x2100,symbol)||std::memcmp(symbol.data(),"BRMenuQueueHook15",17)!=0)return false;
    return true;
}

std::atomic<float> projectionScale{1};
std::atomic<uint64_t> projectionCallbacks{0};
bool aspectBridgeReady(uint64_t base) {
    std::array<uint32_t,6> manifest{};uint32_t entry=0;
    return base&&read(base+0x2f00,manifest)&&std::memcmp(manifest.data(),"BR17VIEW",8)==0&&manifest[2]==1&&
        manifest[3]==0x9f5fbc&&manifest[4]==0x2500&&manifest[5]==0x2d00&&
        read(base+0x9f5fbc,entry)&&entry==0x17d83151U;
}
NSString *aimContext=@"Ожидание персонажа";
BRAim::Vec aimVec(V3 p) {return {p.x,p.y,p.z};}
V3 aimPoint(const AimActor &a,V3 root,bool head) {
    return head?V3{root.x+a.head.x,root.y+a.head.y,root.z+a.head.z}:V3{root.x+a.offset.x,root.y+a.offset.y,root.z+a.offset.z};
}
void resetAimTarget() {std::lock_guard<std::mutex> lock(aimMutex);aimHasChosen=false;aimRange=0;}
void tickAimContext() {
    if(!aimEnabled.load(std::memory_order_relaxed))return;
    Local s;Weapon w;float range=0,health=0;uint32_t state=0;bool valid=false;
    NSString *reason=@"Ожидание персонажа или несовпадение UUID клиента";
    if(getLocal(s)) {
        if(s.vehicle)reason=@"Наведение поддерживается пешком";
        else if(!read(s.ped+0x4b0,health)||!read(s.ped+0x494,state)||!BRAim::living(health,health,state))reason=@"Свой персонаж мёртв или в стадии смерти";
        else if(!getWeapon(s,w))reason=@"Не найдено поддерживаемое огнестрельное оружие";
        else if(!read(w.info+0x28,range)||!std::isfinite(range)||range<=.1||range>=10000)reason=@"Не удалось прочитать дальность оружия";
        else {valid=true;reason=@"Оружие и персонаж готовы";}
    }
    std::lock_guard<std::mutex> lock(aimMutex);
    aimOwnID=valid?s.id:UINT16_MAX;aimRange=valid?range:0;if(valid)aimOwnPosition=s.position;
    aimContext=reason;if(!valid)aimHasChosen=false;
}
using AimQueue=uint32_t(*)(void *,uint32_t,const V3 *,const V3 *);

enum class ModelAction {None,Skin,Weapon,Car};
struct ModelPending {ModelAction action=ModelAction::None;Local owner{};VehicleRef vehicle{};uint32_t model=0,weapon=0,ammo=0;double started=0;bool invoked=false;};
ModelPending modelPending;
NSString *modelStatus=@"Подмена моделей не выполнялась";
struct SkinOriginal {uint64_t ped=0,local=0;uint16_t id=0;uint32_t model=0;};
SkinOriginal skinOriginal;
struct CarOriginal {VehicleRef vehicle{};uint32_t model=0;};
CarOriginal carOriginal;
struct StreamKey {uint64_t kind=0;uint32_t id=0,pad=0;uint64_t extra=0;};
static_assert(sizeof(StreamKey)==24,"Client model-key ABI");
bool modelAnchors(uint64_t base) {
    return anchorAt(base,0x10a084,0xd10183ffU)&&anchorAt(base,0x112b04,0xb9400820U)&&
        anchorAt(base,0x951400,0xd10703ffU)&&anchorAt(base,0x9d6124,0xa9bd57f6U)&&anchorAt(base,0x9d6aa8,0xd10143ffU);
}
void cancelModelPending() {
    if(modelPending.action!=ModelAction::None)modelStatus=@"Ожидающая подмена отменена";
    modelPending={};
}
NSString *beginModelAction(const Local &s,ModelAction action,uint32_t value,uint32_t ammo=300) {
    if(modelPending.action!=ModelAction::None)return @"Дождись загрузки модели или отмени подмену";
    if(!modelAnchors(s.base)||!sameLocal(s))return @"Функции моделей не прошли проверку";
    uint32_t model=value;VehicleRef car{};
    if(action==ModelAction::Weapon) {
        if(value<1||value>254||ammo<1||ammo>99999)return @"ID оружия: 1–254, патроны: 1–99999";
        const uint64_t info=weaponDefinition(s.base,uint8_t(value));uint64_t brain=0;uint32_t fire=0;
        if(!info||!read(info+0x20,fire)||fire!=1||!read(info+0xdc,model)||!hasWeaponSlot(s,uint8_t(value),info,brain))return @"Для этого оружия нет поддерживаемого слота";
        if(!modelCatalog(s.base,model))return @"Модель оружия не найдена в клиенте";
    } else if(action==ModelAction::Skin) {
        if(!modelCatalog(s.base,model,7))return @"Такого ID скина нет в каталоге клиента";
        if(skinOriginal.ped!=s.ped||skinOriginal.local!=s.local||skinOriginal.id!=s.id) {
            uint32_t original=0;if(!read(s.ped+0x98,original))return @"Текущий скин недоступен";
            skinOriginal={s.ped,s.local,s.id,original};
        }
    } else if(action==ModelAction::Car) {
        if(!s.vehicle||!vehicleRef(s.base,s.vehicle,car))return @"Сядь за руль загруженной машины";
        uint32_t kind=0,newKind=0,oldModel=0;uint64_t driver=0;
        const uint64_t info=modelCatalog(s.base,model,6);
        if(!info||!read(info+0x5c,newKind)||newKind!=0||!read(s.vehicle+0x430,kind)||kind!=0||
           !read(s.vehicle+0x2f0,driver)||driver!=s.ped)return @"Подмена пока поддерживает обычные автомобили и место водителя";
        std::array<uint64_t,8> passengers{};
        if(!copy(s.vehicle+0x2f8,passengers.data(),sizeof(passengers))||std::any_of(passengers.begin(),passengers.end(),[](uint64_t p){return p!=0;}))return @"Для подмены высади пассажиров";
        if(carOriginal.vehicle.vehicle!=car.vehicle||carOriginal.vehicle.net!=car.net||!liveVehicle(carOriginal.vehicle)) {
            if(!read(s.vehicle+0x98,oldModel))return @"Текущая модель недоступна";
            carOriginal={car,oldModel};
        }
    }
    const uint64_t slot=streamSlot(s.base,model);
    if(!slot)return @"Ресурс модели отсутствует в этой сборке";
    modelPending={action,s,car,model,value,ammo,NSProcessInfo.processInfo.systemUptime,false};
    StreamKey key{};key.id=model;
    using Request=void(*)(const StreamKey *,uint32_t);
    reinterpret_cast<Request>(s.base+0x10a084)(&key,8);
    modelStatus=@"Загрузка модели · подмена будет применена автоматически";
    return modelStatus;
}
void tickModels() {
    if(modelPending.action==ModelAction::None)return;
    const ModelPending job=modelPending;Local s;
    if(NSProcessInfo.processInfo.systemUptime-job.started>20) {modelPending={};modelStatus=@"Модель не загрузилась за 20 секунд";return;}
    if(!getLocal(s)||s.ped!=job.owner.ped||s.local!=job.owner.local||s.id!=job.owner.id) {cancelModelPending();return;}
    if(job.action==ModelAction::Skin&&job.invoked) {
        uint32_t current=0;
        if(read(s.ped+0x98,current)&&current==job.model) {modelPending={};modelStatus=@"Скин изменён локально";}
        return;
    }
    const uint64_t slot=streamSlot(s.base,job.model);uint8_t ready=0;
    if(!slot||!read(slot+0x48,ready)||ready!=1)return;
    if(job.action==ModelAction::Skin) {
        if(!modelCatalog(s.base,job.model,7)){cancelModelPending();return;}
        std::array<uint32_t,3> payload{s.id,job.model,0}; // Bitstream constructor reads bytes + one padding byte.
        struct RPC {const void *input;uint32_t bits;uint32_t padding;std::array<uint64_t,6> tail;};
        RPC rpc{payload.data(),64,0,{}};
        using SkinRPC=void(*)(const RPC *);
        modelPending.invoked=true;
        reinterpret_cast<SkinRPC>(s.base+0x951400)(&rpc);
        modelStatus=@"Клиент применяет скин";
    } else if(job.action==ModelAction::Weapon) {
        uint64_t brain=0;const uint64_t info=weaponDefinition(s.base,uint8_t(job.weapon));
        if(!info||!hasWeaponSlot(s,uint8_t(job.weapon),info,brain)||!sameLocal(s)){cancelModelPending();return;}
        using Give=uint32_t(*)(void *,uint32_t,uint32_t);
        using Select=void(*)(void *,uint32_t);
        const uint32_t index=reinterpret_cast<Give>(s.base+0x9d6124)(reinterpret_cast<void *>(brain),job.weapon,job.ammo)&255;
        uint64_t begin=0,end=0;
        if(index==255||!read(brain+0x48,begin)||!read(brain+0x50,end)||end<begin||index>=(end-begin)/32) {modelPending={};modelStatus=@"Клиент отказал в выдаче оружия";return;}
        reinterpret_cast<Select>(s.base+0x9d6aa8)(reinterpret_cast<void *>(brain),index);
        Weapon active{};modelPending={};
        modelStatus=getWeapon(s,active)&&active.id==job.weapon?@"Оружие выдано и выбрано локально":@"Оружие добавлено; выбор активного слота не подтверждён";
    } else if(job.action==ModelAction::Car) {
        uint32_t kind=0;uint64_t driver=0,vtable=0,setter=0,deleter=0,metaData=0;
        const uint64_t info=modelCatalog(s.base,job.model,6);
        auto fail=[&](NSString *reason) {modelPending={};modelStatus=reason;};
        if(!info||!read(info+0x5c,kind)||kind!=0) {fail(@"Подмена: целевая модель не является обычным автомобилем");return;}
        if(!read(info+0x48,metaData)||!metaData) {modelStatus=@"Ожидание RwObjectWithLods автомобиля";return;}
        if(!liveVehicle(job.vehicle)||s.vehicle!=job.vehicle.vehicle) {fail(@"Подмена: текущий автомобиль сменился");return;}
        if(!read(s.vehicle+0x2f0,driver)||driver!=s.ped) {fail(@"Подмена: требуется место водителя");return;}
        if(!read(s.vehicle,vtable)||!read(vtable+0x28,setter)||!read(vtable+0x40,deleter)) {fail(@"Подмена: таблица функций автомобиля недоступна");return;}
        if(setter!=s.base+0xabfdc8||deleter!=s.base+0xaf7cc8) {
            fail([NSString stringWithFormat:@"Подмена: неподдерживаемый класс, setter=%llx / delete=%llx",(unsigned long long)(setter-s.base),(unsigned long long)(deleter-s.base)]);return;
        }
        if(!anchorAt(s.base,0xabfdc8,0xa9be4ff4U)||!anchorAt(s.base,0xaf7cc8,0xa9ba6ffcU)||
           !anchorAt(s.base,0x119130,0xa9bd57f6U)||!anchorAt(s.base,0x1190cc,0x39423408U)) {fail(@"Подмена: функции автомобиля не прошли проверку");return;}
        std::array<uint64_t,8> passengers{};
        if(!copy(s.vehicle+0x2f8,passengers.data(),sizeof(passengers))||std::any_of(passengers.begin(),passengers.end(),[](uint64_t p){return p!=0;})) {cancelModelPending();return;}
        Matrix pose{};if(!read(s.vehicle+8,pose)){cancelModelPending();return;}
        using Unary=void(*)(void *);using ModelSet=void(*)(void *,uint32_t);
        auto vehicle=reinterpret_cast<void *>(s.vehicle);
        restoreVehicleGuard();
        reinterpret_cast<Unary>(s.base+0x119130)(vehicle);
        reinterpret_cast<Unary>(deleter)(vehicle);
        reinterpret_cast<ModelSet>(setter)(vehicle,job.model);
        (void)writeData(s.vehicle+8,pose);const uint8_t dirty=1;(void)writeData(s.vehicle+0x60,dirty);
        reinterpret_cast<Unary>(s.base+0x1190cc)(vehicle);
        VehicleRef refreshed{};
        if(vehicleRef(s.base,s.vehicle,refreshed)) {
            if(carOriginal.vehicle.vehicle==s.vehicle)carOriginal.vehicle=refreshed;
            if(carGravity.entity==s.vehicle)carGravity.ref=refreshed;
        }
        uint32_t current=0;modelPending={};
        modelStatus=read(s.vehicle+0x98,current)&&current==job.model?@"Модель автомобиля заменена локально; прежний handling сохранён":@"Подмена автомобиля не подтверждена";
    }
}

// The map's user waypoint is a generation-tagged radar trace (sprite 41).
// We read the same handle/trace fields written by 0x101a3c; no map RPC is sent.
struct WaypointJob {bool active=false;Local owner{};V3 origin{},target{};double started=0;};
WaypointJob waypointJob;
bool waypoint(uint64_t base,V3 &p) {
    if(!anchorAt(base,0x101a3c,0xd105c3ffU)||!anchorAt(base,0xfdaac,0x3100041fU))return false;
    uint32_t handle=UINT32_MAX;uint16_t generation=0,sprite=0;uint8_t active=0;uint32_t type=0;
    if(!read(base+0x19cbb98,handle)||handle==UINT32_MAX||(handle&0xffff)>=75)return false;
    const uint64_t trace=base+0x2ed2124+uint64_t(handle&0xffff)*0x38;
    return read(trace+0x24,generation)&&generation==(handle>>16)&&read(trace+0x27,active)&&active==1&&
        read(trace+4,type)&&type==4&&read(trace+0x34,sprite)&&sprite==41&&read(trace+0xc,p)&&destination(p);
}
bool waypointGround(const Local &s,V3 point,float &height) {
    if(!anchorAt(s.base,0x11f89c,0xd10203ffU))return false;
    uint8_t found=0;
    using Ground=float(*)(float,float,float,uint8_t *);
    height=reinterpret_cast<Ground>(s.base+0x11f89c)(point.x,point.y,1000,&found);
    return found==1&&std::isfinite(height)&&height>=-500&&height<999;
}
void cancelWaypoint(bool restore) {
    const WaypointJob job=waypointJob;waypointJob={};
    if(!job.active)return;
    Local s;
    if(restore&&getLocal(s)&&s.ped==job.owner.ped&&s.local==job.owner.local&&s.id==job.owner.id&&!s.vehicle)
        (void)teleport(s,job.origin);
    modelStatus=@"Телепорт по метке отменён";
}
NSString *beginWaypoint(const Local &s) {
    if(s.vehicle)return @"Телепорт по метке: сначала выйди из машины";
    if(modelPending.action!=ModelAction::None)return @"Сначала дождись подмены модели";
    V3 point{};if(!waypoint(s.base,point))return @"Поставь пользовательскую метку на карте";
    float height=0;
    if(waypointGround(s,point,height)) {point.z=height+1.0f;return teleport(s,point);}
    // Move above the destination so the ordinary world streamer can load it.
    // While waiting, hold position; on timeout restore the departure point.
    point.z=500;
    NSString *result=teleport(s,point);
    if(![result isEqualToString:@"Локальная команда телепорта выполнена"])return result;
    waypointJob={true,s,s.position,point,NSProcessInfo.processInfo.systemUptime};
    modelStatus=@"Метка: ожидание коллизии земли (до 8 секунд)";
    return modelStatus;
}
void tickWaypoint() {
    if(!waypointJob.active)return;
    const WaypointJob job=waypointJob;Local s;
    if(!getLocal(s)||s.ped!=job.owner.ped||s.local!=job.owner.local||s.id!=job.owner.id||s.vehicle) {cancelWaypoint(false);return;}
    if(NSProcessInfo.processInfo.systemUptime-job.started>8) {
        cancelWaypoint(true);modelStatus=@"Земля у метки не загрузилась: отправлена команда возврата";return;
    }
    // Stop if the host/server moved the actor away during streaming.
    const double dx=s.position.x-job.target.x,dy=s.position.y-job.target.y;
    if(dx*dx+dy*dy>100) {cancelWaypoint(false);modelStatus=@"Телепорт по метке остановлен: позиция изменена клиентом";return;}
    float height=0;
    if(waypointGround(s,job.target,height)) {
        V3 target=job.target;target.z=height+1.0f;waypointJob={};
        modelStatus=teleport(s,target);return;
    }
    const V3 zero{};const uint8_t dirty=1;
    if(!writeData(s.ped+0x38,job.target)||!writeData(s.ped+0x180,zero)||!writeData(s.ped+0x60,dirty))cancelWaypoint(true);
}

}

// The on-disk bridge passes its original trampoline as argument five.
// No text protection changes, JIT pages or runtime instruction writes are used.
extern "C" __attribute__((used,visibility("default")))
uint32_t BRMenuQueueHook15(void *owner,uint32_t weapon,const V3 *from,const V3 *to,AimQueue original) noexcept {
    if(!original)return 0;
    aimCallbacks.fetch_add(1,std::memory_order_relaxed);
    V3 output{};bool redirect=false;
    if(aimEnabled.load(std::memory_order_relaxed)) {
        @autoreleasepool {
            AimActor chosen{};BRAim::View view{};bool selected=false,head=false;double miss=0,received=0;uint64_t generation=0;
            {std::lock_guard<std::mutex> lock(aimMutex);
                selected=aimSettings.enabled&&aimHasChosen;
                if(selected) {chosen=aimChosen;view=aimSettings.view;head=aimSettings.head;miss=aimSettings.miss;received=aimReceived;generation=aimConfigGeneration;}
            }
            Local s;V3 start{},end{},root{};uint64_t remote=0,ped=0;uint16_t id=UINT16_MAX;
            float hp=0,physicalHP=0,ownHP=0;uint32_t state=0,ownState=0;
            if(selected&&NSProcessInfo.processInfo.systemUptime-received<=0.3&&getLocal(s)&&reinterpret_cast<uint64_t>(owner)==s.ped&&
               !s.vehicle&&read(s.ped+0x4b0,ownHP)&&read(s.ped+0x494,ownState)&&BRAim::living(ownHP,ownHP,ownState)&&chosen.id<1504&&chosen.id!=s.id&&read(s.pool+8+uint64_t(chosen.id)*8,remote)&&remote==chosen.remote&&
               read(remote+0x10,ped)&&ped==chosen.ped&&read(remote+0x4a,id)&&id==chosen.id&&
               read(remote+0x148,hp)&&read(ped+0x4b0,physicalHP)&&read(ped+0x494,state)&&BRAim::living(hp,physicalHP,state)&&
               read(ped+0x38,root)&&finite(root)&&copy(reinterpret_cast<uint64_t>(from),&start,sizeof(start))&&
               copy(reinterpret_cast<uint64_t>(to),&end,sizeof(end))) {
                // Identity reuse with a different nickname invalidates the selected actor.
                char currentNick[50]={0};bool sameNick=false;
                if(copy(remote+0x18,currentNick,49)) {
                    NSString *name=[[NSString alloc] initWithUTF8String:currentNick];
                    if(!name)name=[[NSString alloc] initWithBytes:currentNick length:strnlen(currentNick,49) encoding:NSWindowsCP1251StringEncoding];
                    const char *folded=name.lowercaseString.UTF8String;
                    sameNick=folded&&std::strcmp(folded,chosen.nick.data())==0;
                }
                Matrix camera{};const V3 target=aimPoint(chosen,root,head);
                const uint64_t info=weapon<255?weaponDefinition(s.base,uint8_t(weapon)):0;uint32_t fire=0;
                if(sameNick&&info&&read(info+0x20,fire)&&fire==1&&read(s.base+0x22892a0+0x900,camera)) {
                    std::copy(std::begin(camera.v),std::end(camera.v),view.m.begin());
                    BRAim::Vec adjusted{};
                    if(BRAim::score(view,aimVec(target))>=0&&BRAim::endpoint(aimVec(start),aimVec(end),aimVec(target),adjusted)) {
                        if(BRAim::skip(arc4random_uniform(10000),miss))aimSkipped.fetch_add(1,std::memory_order_relaxed);
                        else {
                            std::lock_guard<std::mutex> lock(aimMutex);
                            if(generation==aimConfigGeneration&&aimSettings.enabled&&!aimSettings.excluded[chosen.id]&&!aimSettings.names.count(chosen.nick.data())) {
                                output={float(adjusted.x),float(adjusted.y),float(adjusted.z)};redirect=true;
                            }
                        }
                    }
                }
            }
        }
    }
    if(redirect&&!aimEnabled.load(std::memory_order_relaxed))redirect=false;
    if(redirect)aimRedirects.fetch_add(1,std::memory_order_relaxed);
    return original(owner,weapon,from,redirect?&output:to);
}

extern "C" __attribute__((used,visibility("default")))
float BRMenuAspectHook17(float naturalAspect) noexcept {
    projectionCallbacks.fetch_add(1,std::memory_order_relaxed);
    const float scale=projectionScale.load(std::memory_order_relaxed);
    return BRAim::projectionRatio(naturalAspect,scale);
}

@implementation BRPlayerSnapshot
+ (void)configureAspect:(double)scale {
    projectionScale.store(std::isfinite(scale)?float(std::clamp(scale,1.0,1.6)):1,std::memory_order_relaxed);
}
+ (NSDictionary<NSString *,id> *)aspectState {
    const uint64_t base=imageBase();const bool installed=aspectBridgeReady(base);
    const bool exported=installed&&dlsym(RTLD_DEFAULT,"BRMenuAspectHook17")==reinterpret_cast<void *>(&BRMenuAspectHook17);
    return @{@"ready":@(exported),@"observed":@(projectionCallbacks.load()>0),@"callbacks":@(projectionCallbacks.load())};
}

+ (void)configureAim:(NSDictionary<NSString *,id> *)settings {
    AimSettings next;next.enabled=[settings[@"enabled"] boolValue];next.head=[settings[@"head"] boolValue];
    const double radius=[settings[@"radius"] doubleValue],miss=[settings[@"miss"] doubleValue];
    next.view.radius=std::isfinite(radius)?std::clamp(radius,30.0,300.0):100;
    next.miss=std::isfinite(miss)?std::clamp(miss,0.0,100.0):0;
    NSString *text=[settings[@"whitelist"] isKindOfClass:NSString.class]?settings[@"whitelist"]:@"";
    if(text.length>8192)text=[text substringToIndex:8192];
    NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@",; \t\r\n"];
    for(NSString *token in [text componentsSeparatedByCharactersInSet:separators]) {
        if(!token.length)continue;
        NSScanner *scanner=[NSScanner scannerWithString:token];long long id=0;
        if([scanner scanLongLong:&id]&&[scanner isAtEnd]) {if(id>=0&&id<1504)next.excluded[size_t(id)]=true;}
        else {const char *value=token.lowercaseString.UTF8String;if(value)next.names.insert(value);}
    }
    {std::lock_guard<std::mutex> lock(aimMutex);next.view.width=aimSettings.view.width;next.view.height=aimSettings.view.height;next.view.stretch=aimSettings.view.stretch;aimSettings=std::move(next);aimHasChosen=false;++aimConfigGeneration;}
    aimEnabled.store([settings[@"enabled"] boolValue],std::memory_order_relaxed);
}
+ (NSDictionary<NSString *,id> *)aimFrame:(double)width height:(double)height stretch:(double)stretch {
    const uint64_t base=verifiedProjectionBase.load(std::memory_order_acquire);const bool bridge=aimBridgeReady(base);
    const bool exported=bridge&&dlsym(RTLD_DEFAULT,"BRMenuQueueHook15")==reinterpret_cast<void *>(&BRMenuQueueHook15);
    const bool ready=bridge&&exported;
    Matrix camera{};const bool hasCamera=base&&read(base+0x22892a0+0x900,camera);
    const double now=NSProcessInfo.processInfo.systemUptime;
    std::lock_guard<std::mutex> lock(aimMutex);
    auto &settings=aimSettings;auto &view=settings.view;view.width=width;view.height=height;view.stretch=stretch;
    if(hasCamera)std::copy(std::begin(camera.v),std::end(camera.v),view.m.begin());
    aimHasChosen=false;double x=0,y=0;
    if(settings.enabled&&hasCamera&&aimRange>0&&now-aimReceived<=0.3) {
        std::array<BRAim::Candidate,128> candidates{};
        for(size_t i=0;i<aimCount;++i) {
            const auto &a=aimActors[i];
            const bool excluded=a.id>=1504||settings.excluded[a.id]||(!settings.names.empty()&&settings.names.count(a.nick.data()));
            candidates[i]={a.id,aimVec(aimPoint(a,a.root,settings.head)),a.hp,a.physicalHP,a.state,excluded};
        }
        const auto selected=BRAim::choose(view,aimVec(aimOwnPosition),aimRange,aimOwnID,candidates.data(),aimCount);
        if(selected.found) {aimChosen=aimActors[selected.index];aimHasChosen=true;}

    }
    if(aimHasChosen) {
        // Label above the selected actor; target itself can be chest or head.
        V3 p=aimPoint(aimChosen,aimChosen.root,true);p.z+=0.35f;
        if(!BRAim::project(view,aimVec(p),x,y)) {p=aimPoint(aimChosen,aimChosen.root,settings.head);(void)BRAim::project(view,aimVec(p),x,y);}
    }
    const uint64_t callbacks=aimCallbacks.load();
    NSString *status;
    if(!base)status=@"Модуль клиента ещё не найден";
    else if(!bridge)status=@"В установленной IPA нет исправного перехода Silent Aim · нужна IPA с патчем";
    else if(!exported)status=@"Загружена другая копия меню или символ перехвата скрыт";
    else if(!settings.enabled)status=@"Silent Aim выключен";
    else if(aimRange<=0)status=aimContext;
    else if(now-aimReceived>0.3)status=@"Данные игроков устарели или ещё не получены";
    else if(!aimCount)status=@"Нет загруженных игроков в радиусе сбора ESP";
    else if(callbacks==0)status=@"Переход установлен · сделай обычный выстрел: пока 0 вызовов";
    else status=aimHasChosen?@"Перехват вызван · цель выбрана":@"Перехват вызван · живой цели в FOV нет";
    return @{@"ready":@(ready),@"observed":@(callbacks>0),@"target":@(aimHasChosen?int(aimChosen.id):-1),@"x":@(x),@"y":@(y),@"status":status,
        @"candidates":@(aimCount),@"range":@(aimRange),@"context":aimContext,@"ageMs":@(std::max(0.0,now-aimReceived)*1000),
        @"callbacks":@(callbacks),@"redirects":@(aimRedirects.load()),@"skipped":@(aimSkipped.load())};
}

+ (void)stopControls {
    @synchronized(self) {
        const Flight old=flight;flight={};assists={};cancelModelPending();cancelWaypoint(true);aimEnabled.store(false);resetAimTarget();projectionScale.store(1);
        Local s;
        if([NSThread isMainThread]&&getLocal(s)) {
            updatePedFlags(s);restoreVehicleGuard();restoreSpread();updateAnimations(s);
            if(old.active&&s.ped==old.ped&&s.local==old.local) (void)teleport(s,old.point);
            (void)restoreMass(s,pedMass,s.ped);(void)restoreMass(s,vehicleMass,s.vehicle);
            (void)restoreGravity(s,pedGravity);(void)restoreGravity(s,carGravity);
        } else {restoreSpread();animationState={};pedMass={};vehicleMass={};pedFlags={};restoreVehicleGuard();Local empty{};(void)restoreGravity(empty,carGravity);pedGravity={};}
    }
}
+ (void)configureControls:(NSDictionary<NSString *,NSNumber *> *)settings {
    if(![NSThread isMainThread])return;
    @synchronized(self) {
        assists.health=settings[@"autoHealth"].boolValue;assists.armor=settings[@"autoArmor"].boolValue;
        assists.stamina=settings[@"stamina"].boolValue;assists.vehicleHealth=settings[@"autoVehicleHealth"].boolValue;
        assists.slowFall=settings[@"slowFall"].boolValue;assists.noClip=settings[@"noClip"].boolValue;
        assists.proof=settings[@"localProof"].boolValue;assists.noFall=settings[@"noFall"].boolValue;
        assists.vehicleProof=settings[@"vehicleProof"].boolValue;assists.ammo=settings[@"infiniteAmmo"].boolValue;
        assists.noCollision=settings[@"noCollision"].boolValue;assists.noSpread=settings[@"noSpread"].boolValue;
        assists.noAnim=settings[@"noAnim"].boolValue;assists.fastAnim=settings[@"fastAnim"].boolValue;
        const double animationRate=settings[@"animationRate"].doubleValue;
        assists.animationRate=std::isfinite(animationRate)?std::clamp(animationRate,1.0,4.0):2;
        assists.magazine=settings[@"noReload"].boolValue;assists.rapid=settings[@"rapidFire"].boolValue;
        const double rate=settings[@"fireRate"].doubleValue;assists.fireRate=std::isfinite(rate)?std::clamp(rate,1.0,5.0):2.0;
        Local s;if(getLocal(s)){updatePedFlags(s);updateVehicleGuard(s);updateSpread(s);updateAnimations(s);}else if(!assists.noSpread)restoreSpread();
    }
}
+ (void)tickControls:(double)elapsed {
    if(![NSThread isMainThread])return;
    @synchronized(self) {
        tickModels();
        tickWaypoint();
        tickAimContext();
        if(!flight.active&&!assists.health&&!assists.armor&&!assists.stamina&&!assists.vehicleHealth&&!assists.slowFall&&
           !assists.noCollision&&!assists.noSpread&&!assists.noAnim&&!assists.fastAnim&&!spreadBackup.info&&animationState.entries.empty()&&!assists.proof&&!assists.noFall&&!assists.vehicleProof&&!assists.ammo&&!assists.magazine&&!assists.rapid&&!pedFlags.ped&&!vehicleGuard.active)return;
        Local s;
        if(!std::isfinite(elapsed)||elapsed<=0||elapsed>0.25||!getLocal(s)) {flight={};return;}
        updatePedFlags(s);updateVehicleGuard(s);weaponAssists(s);updateSpread(s);updateAnimations(s);
        uint32_t pedAnchor=0,carAnchor=0,staminaAnchor=0;
        const bool pedVerified=read(s.base+0x9c394c,pedAnchor)&&pedAnchor==0xbd04b260U;
        const bool carVerified=read(s.base+0x943f04,carAnchor)&&carAnchor==0xbd039900U;
        const bool staminaVerified=read(s.base+0x9d2ad0,staminaAnchor)&&staminaAnchor==0xbd088260U;
        float health=0;
        const bool alive=pedVerified&&read(s.ped+0x4b0,health)&&std::isfinite(health)&&health>0&&health<=10000;
        if(alive&&sameLocal(s)) {
            const float hundred=100;
            if(assists.health&&health<100)(void)writeData(s.ped+0x4b0,hundred);
            float armor=0;
            if(assists.armor&&read(s.ped+0x4b8,armor)&&std::isfinite(armor)&&armor>=0&&armor<100)(void)writeData(s.ped+0x4b8,hundred);
            if(assists.stamina&&staminaVerified&&!s.vehicle) {
                float current=0,maximum=0;
                if(read(s.ped+0x880,current)&&read(s.ped+0x884,maximum)&&std::isfinite(current)&&std::isfinite(maximum)&&
                   current>=-1000&&current<=10000&&maximum>=10&&maximum<=1000&&current<maximum)
                    (void)writeData(s.ped+0x880,maximum);
            }
            if(assists.slowFall&&!s.vehicle&&s.velocity.z < -0.1f) {const float limit=-0.1f;(void)writeData(s.ped+0x188,limit);}
        }
        if(assists.vehicleHealth&&carVerified&&s.vehicle&&sameLocal(s)) {
            float hp=0;
            if(read(s.vehicle+0x398,hp)&&std::isfinite(hp)&&hp>0&&hp<1000) {const float full=1000;(void)writeData(s.vehicle+0x398,full);}
        }
        if(!flight.active)return;
        if(s.vehicle||s.ped!=flight.ped||s.local!=flight.local) {flight={};updatePedFlags(s);return;}
        Matrix camera{};
        if(!read(s.base+0x22892a0+0x900,camera)) {flight={};return;}
        // The view matrix's depth and x rows provide horizontal forward/right.
        V3 forward{camera.v[2],camera.v[6],0},right{camera.v[0],camera.v[4],0};
        float fl=std::hypot(forward.x,forward.y),rl=std::hypot(right.x,right.y);
        if(!finite(forward)||!finite(right)||fl<0.001||rl<0.001) {
            flight.input.x=0;flight.input.y=0;
            forward={0,1,0};right={1,0,0};fl=1;rl=1;
        }
        const float delta=static_cast<float>(flight.speed*elapsed);
        V3 next=flight.point;
        next.x+=delta*(forward.x/fl*flight.input.y+right.x/rl*flight.input.x);
        next.y+=delta*(forward.y/fl*flight.input.y+right.y/rl*flight.input.x);
        next.z+=delta*flight.input.z;
        if(!destination(next)||!sameLocal(s)) {flight={};return;}
        V3 zero{};const uint8_t dirty=1;
        if(!writeData(s.ped+0x180,zero)||!writeData(s.ped+0x38,next)||!writeData(s.ped+0x60,dirty)) {flight={};return;}
        flight.point=next;
    }
}
+ (NSDictionary<NSString *,id> *)localState {
    @synchronized(self) {
        Local s;if(!getLocal(s))return @{};
        float health=0,armor=0,stamina=0,maximum=0,vehicleHealth=0;
        (void)read(s.ped+0x4b0,health);(void)read(s.ped+0x4b8,armor);
        (void)read(s.ped+0x880,stamina);(void)read(s.ped+0x884,maximum);
        if(s.vehicle)(void)read(s.vehicle+0x398,vehicleHealth);
        Weapon weapon{};const bool hasWeapon=getWeapon(s,weapon);
        float gravity=0;(void)read(s.ped+0x170,gravity);
        uint16_t carID=0;if(s.vehicle)(void)read(s.vehicle+0x434,carID);
        uint32_t skin=0,carModel=0;(void)read(s.ped+0x98,skin);if(s.vehicle)(void)read(s.vehicle+0x98,carModel);
        return @{@"modelStatus":modelStatus,@"skin":@(skin),@"carModel":@(carModel),@"modelPending":@(modelPending.action!=ModelAction::None),@"weapon":@(hasWeapon?int(weapon.id):-1),@"clip":@(hasWeapon?weapon.clip:-1),@"ammo":@(hasWeapon?weapon.total:-1),
            @"capacity":@(hasWeapon?int(weapon.capacity):-1),@"carID":@(s.vehicle?int(carID):-1),@"gravity":@(std::isfinite(gravity)?gravity:0),
            @"vehicleProtected":@(vehicleGuard.active),@"flightActive":@(flight.active),@"id":@(s.id),@"x":@(s.position.x),@"y":@(s.position.y),@"z":@(s.position.z),
            @"hp":@(std::isfinite(health)?health:-1),@"armor":@(std::isfinite(armor)?armor:-1),
            @"stamina":@(std::isfinite(stamina)?stamina:-1),@"maxStamina":@(std::isfinite(maximum)?maximum:-1),
            @"vehicleHP":@(std::isfinite(vehicleHealth)?vehicleHealth:-1),@"inVehicle":@(s.vehicle!=0)};
    }
}
+ (NSString *)performAction:(NSString *)action values:(NSDictionary<NSString *,NSNumber *> *)values {
    if(![NSThread isMainThread])return @"Команда доступна только в главном потоке";
    @synchronized(self) {
        // Release/stop must never be throttled, even when the actor disappears.
        if([action isEqualToString:@"flightRelease"]) {flight.input={};return @"AirBrake: остановка движения";}
        if([action isEqualToString:@"flightStop"]) {flight={};return @"AirBrake выключен";}
        if([action isEqualToString:@"flightInput"]) {
            V3 input{values[@"x"].floatValue,values[@"y"].floatValue,values[@"z"].floatValue};
            double speed=values[@"speed"].doubleValue;
            if(!flight.active)return @"Сначала включи AirBrake";
            if(!finite(input)||std::abs(input.x)>1||std::abs(input.y)>1||std::abs(input.z)>1||!std::isfinite(speed)||speed<1||speed>30)return @"Некорректное направление";
            flight.input=input;flight.speed=speed;return @"AirBrake: движение";
        }
        if([action isEqualToString:@"waypointCancel"]) {cancelWaypoint(true);return modelStatus;}
        static double lastAction=-100;
        const double now=NSProcessInfo.processInfo.systemUptime;
        if(now-lastAction<0.4)return @"Подожди перед следующей командой";
        Local s;if(!getLocal(s))return @"Персонаж не найден или сборка клиента не совпадает";
        if(waypointJob.active)return @"Дождись телепорта по метке или отмени его";
        if([action isEqualToString:@"waypoint"]) {lastAction=now;return beginWaypoint(s);}
        if([action isEqualToString:@"flightToggle"]) {
            if(flight.active) {
                const Flight old=flight;flight={};
                lastAction=now;
                updatePedFlags(s);
                if(s.ped!=old.ped||s.local!=old.local)return @"AirBrake выключен: персонаж сменился";
                return teleport(s,old.point);
            }
            if(modelPending.action!=ModelAction::None)return @"Дождись подмены модели или отмени её";
            if(s.vehicle)return @"Для AirBrake выйди из транспорта";
            flight.active=true;flight.ped=s.ped;flight.local=s.local;flight.point=s.position;
            lastAction=now;return @"AirBrake включён";
        }
        if(flight.active)return @"Сначала выключи AirBrake";
        if([action isEqualToString:@"modelCancel"]) {cancelModelPending();return @"Ожидающая подмена отменена";}
        if([action isEqualToString:@"unlockVehicle"]||[action isEqualToString:@"startEngine"]) {
            uint64_t car=s.vehicle;
            if(!car&&[action isEqualToString:@"unlockVehicle"]) {
                uint64_t pool=0;if(!read(s.base+0x340de20,pool)||!pool)return @"Транспорт ещё не загружен";
                float best=64;
                for(int i=0;i<2000;++i) {
                    uint64_t net=0,v=0;V3 p{};
                    if(!read(pool+uint64_t(i)*8,net)||!net||!read(net,v)||!v||!read(v+0x38,p)||!finite(p))continue;
                    float d=(p.x-s.position.x)*(p.x-s.position.x)+(p.y-s.position.y)*(p.y-s.position.y)+(p.z-s.position.z)*(p.z-s.position.z);
                    if(d<best){best=d;car=v;}
                }
            }
            VehicleRef ref{};
            if(!car||!vehicleRef(s.base,car,ref)||!liveVehicle(ref)||!sameLocal(s))return @"Нет подходящей машины рядом (до 8 м)";
            if([action isEqualToString:@"unlockVehicle"]) {
                // afc718 rejects door states 2/4/5/7; unlocked state 1 passes.
                if(!anchorAt(s.base,0x944760,0xf9400008U)||!anchorAt(s.base,0xafc728,0xb943bc08U))return @"Замки: версия функции не совпадает";
                using Set=void(*)(void *,uint32_t);reinterpret_cast<Set>(s.base+0x944760)(reinterpret_cast<void *>(ref.net),1);
                lastAction=now;return @"Локальный замок открыт · сервер может закрыть снова";
            }
            uint64_t driver=0;float hp=0;
            if(!s.vehicle||!read(car+0x2f0,driver)||driver!=s.ped)return @"Сначала сядь за руль";
            if(!read(car+0x398,hp)||!std::isfinite(hp)||hp<=250)return @"Сначала отремонтируй двигатель";
            if(!anchorAt(s.base,0x94477c,0xa9be4ff4U)||!anchorAt(s.base,0x9447fc,0xb903812aU))return @"Двигатель: версия функции не совпадает";
            using Engine=void(*)(void *,uint32_t);reinterpret_cast<Engine>(s.base+0x94477c)(reinterpret_cast<void *>(ref.net),1);
            lastAction=now;return @"Локальный двигатель включён · серверные ключи не выдаются";
        }
        if([action isEqualToString:@"suicide"]||[action isEqualToString:@"respawn"]) {
            uint32_t state=0;uint64_t task=0,clump=0;float hp=0;
            if(s.vehicle||!sameLocal(s)||!read(s.ped+0x494,state)||!read(s.ped+0x4b0,hp)||!std::isfinite(hp)||
               !read(s.ped+0x798,task)||!task||!read(s.ped+0x68,clump)||!clump)return @"Действие доступно для загруженного персонажа пешком";
            if([action isEqualToString:@"suicide"]) {
                if(state==52||state==53||hp<=0)return @"Персонаж уже в состоянии смерти";
                if(!anchorAt(s.base,0x99d4c0,0x6dbc23e9U)||!anchorAt(s.base,0x99d664,0xb904b29fU))return @"Функция смерти не прошла проверку";
                flight={};assists.health=false;assists.proof=false;assists.noFall=false;assists.noAnim=false;assists.fastAnim=false;
                updatePedFlags(s);updateAnimations(s);
                using Die=void(*)(void *,uint32_t,float,float);
                reinterpret_cast<Die>(s.base+0x99d4c0)(reinterpret_cast<void *>(s.ped),202,4.f,0.f);
                lastAction=now;return @"Вызвана штатная смерть персонажа";
            }
            if(state!=53)return @"Дождись завершения смерти (DEAD)";
            uint8_t spawnInfo=0;V3 point{};float heading=0;
            if(!read(s.local+0x1d4,spawnInfo)||spawnInfo!=1||!read(s.local+0x1ac,point)||!destination(point)||
               !read(s.local+0x1b8,heading)||!std::isfinite(heading))return @"Нет сохранённых данных появления от сервера";
            if(!anchorAt(s.base,0x92cce8,0xd10603ffU)||!anchorAt(s.base,0x92cd10,0x39475008U))return @"Функция появления не прошла проверку";
            using Spawn=void(*)(void *);reinterpret_cast<Spawn>(s.base+0x92cce8)(reinterpret_cast<void *>(s.local));
            lastAction=now;return @"Вызван штатный респаун · сервер может отклонить";
        }
        if([action isEqualToString:@"skinRestore"]) {
            if(skinOriginal.ped!=s.ped||skinOriginal.local!=s.local||skinOriginal.id!=s.id)return @"Исходный скин этого персонажа не сохранён";
            lastAction=now;return beginModelAction(s,ModelAction::Skin,skinOriginal.model);
        }
        if([action isEqualToString:@"carRestore"]) {
            if(!s.vehicle||s.vehicle!=carOriginal.vehicle.vehicle||!liveVehicle(carOriginal.vehicle))return @"Исходная модель этой машины не сохранена";
            lastAction=now;return beginModelAction(s,ModelAction::Car,carOriginal.model);
        }
        if([action isEqualToString:@"skinSet"]||[action isEqualToString:@"carSet"]||[action isEqualToString:@"weaponGive"]) {
            double id=values[@"id"].doubleValue,ammo=values[@"ammo"].doubleValue;
            if(!std::isfinite(id)||id<0||id>1000000||id!=std::floor(id))return @"Некорректный ID модели";
            if([action isEqualToString:@"weaponGive"]&&(!std::isfinite(ammo)||ammo<1||ammo>99999||ammo!=std::floor(ammo)))return @"Патроны: 1–99999";
            lastAction=now;
            ModelAction kind=[action isEqualToString:@"skinSet"]?ModelAction::Skin:([action isEqualToString:@"carSet"]?ModelAction::Car:ModelAction::Weapon);
            return beginModelAction(s,kind,uint32_t(id),uint32_t(ammo));
        }
        if([action isEqualToString:@"teleport"]) {
            if(!values[@"x"]||!values[@"y"]||!values[@"z"])return @"Нужны три координаты";
            lastAction=now;
            return teleport(s,V3{values[@"x"].floatValue,values[@"y"].floatValue,values[@"z"].floatValue});
        }
        if([action isEqualToString:@"player"]) {
            double selected=values[@"id"].doubleValue;
            if(!std::isfinite(selected)||selected<0||selected>=1504||selected!=std::floor(selected)||selected==s.id)return @"Нужен ID другого игрока: 0–1503";
            uint64_t remote=0,ped=0,verify=0;uint16_t id=0;V3 p{};
            if(!read(s.pool+8+uint64_t(selected)*8,remote)||!remote||!read(remote+0x4a,id)||id!=selected||
               !read(remote+0x10,ped)||!ped||!read(ped+0x38,p)||!destination(p)||
               !read(s.pool+8+uint64_t(selected)*8,verify)||verify!=remote)return @"Игрок не загружен в клиенте";
            p.z+=1;lastAction=now;return teleport(s,p);
        }
        if([action isEqualToString:@"ammoRefill"]||[action isEqualToString:@"magazineFill"]) {
            Weapon w;if(!getWeapon(s,w)||!sameWeapon(s,w))return @"Возьми поддерживаемое огнестрельное оружие";
            const bool reserve=[action isEqualToString:@"ammoRefill"];
            int32_t total=reserve?std::max(w.total,999):w.total;
            if(total<1)return @"Нет патронов в запасе";
            int32_t clip=std::min(total,int32_t(w.capacity));
            if(reserve&&!writeData(w.address+12,total))return @"Запас патронов недоступен";
            if(!writeData(w.address+8,clip))return @"Магазин недоступен";
            if(w.state==2){const int32_t ready=0;(void)writeData(w.address+4,ready);}
            lastAction=now;return reserve?@"Патроны пополнены локально":@"Магазин заполнен из запаса";
        }
        if([action isEqualToString:@"gravityPed"]||[action isEqualToString:@"gravityVehicle"]||[action isEqualToString:@"gravityReset"]) {
            if([action isEqualToString:@"gravityReset"]) {
                const bool a=restoreGravity(s,pedGravity),b=restoreGravity(s,carGravity);
                return a&&b?@"Исходная гравитация восстановлена":@"Часть объектов уже недоступна";
            }
            const bool car=[action isEqualToString:@"gravityVehicle"];
            uint64_t entity=car?s.vehicle:s.ped;if(!entity)return @"Сначала сядь в транспорт";
            const double factor=values[@"factor"].doubleValue;
            if(!std::isfinite(factor)||factor < -2||factor>3||!anchorAt(s.base,0x152d28,0xbd417000U)||!sameLocal(s))return @"Гравитация недоступна";
            float original=0;VehicleRef ref{};
            if(!read(entity+0x170,original)||!std::isfinite(original)||std::abs(original)>0.05f||(car&&!vehicleRef(s.base,entity,ref)))return @"Значение гравитации не прошло проверку";
            GravityBackup &backup=car?carGravity:pedGravity;
            if(backup.entity!=entity||(!car&&(backup.ped!=s.ped||backup.local!=s.local||backup.id!=s.id))) {
                (void)restoreGravity(s,backup);
                backup.entity=entity;backup.ped=s.ped;backup.local=s.local;backup.id=s.id;
                backup.original=original;backup.car=car;backup.ref=ref;
            }
            const float value=static_cast<float>(std::clamp(double(backup.original)*factor,-0.05,0.05));
            if(!writeData(entity+0x170,value))return @"Не удалось изменить гравитацию";
            lastAction=now;return @"Гравитация изменена для выбранного объекта";
        }
        if([action isEqualToString:@"vehicleTarget"]||[action isEqualToString:@"nearestVehicle"]) {
            if(s.vehicle)return @"Сначала выйди из транспорта";
            uint64_t pool=0;if(!read(s.base+0x340de20,pool)||!pool)return @"Пул транспорта недоступен";
            V3 point{};uint64_t target=0;VehicleRef chosen{};
            if([action isEqualToString:@"vehicleTarget"]) {
                const double id=values[@"id"].doubleValue;
                uint64_t net=0;
                if(!std::isfinite(id)||id<0||id>=2000||id!=std::floor(id)||!read(pool+uint64_t(id)*8,net)||!net||!read(net,target)||!target||
                   !vehicleRef(s.base,target,chosen)||chosen.id!=id||!read(target+0x38,point)||!destination(point))return @"Транспорт с этим ID не загружен";
            } else {
                std::array<uint64_t,2000> slots{};double best=5000.0*5000.0;
                if(!copy(pool,slots.data(),sizeof(slots)))return @"Пул транспорта недоступен";
                for(size_t id=0;id<slots.size();++id) {
                    uint64_t car=0;V3 p{};if(!slots[id]||!read(slots[id],car)||!car||!read(car+0x38,p)||!destination(p))continue;
                    const double dx=p.x-s.position.x,dy=p.y-s.position.y,dz=p.z-s.position.z,d=dx*dx+dy*dy+dz*dz;
                    if(d<best&&vehicleRef(s.base,car,chosen)){best=d;target=car;point=p;}
                }
                if(!target||!vehicleRef(s.base,target,chosen))return @"Рядом нет загруженного транспорта";
            }
            if(!liveVehicle(chosen))return @"Транспорт сменился";
            point.z+=2;lastAction=now;return teleport(s,point);
        }
        if([action isEqualToString:@"repairVehicle"]) {
            VehicleRef ref{};float hp=0;uint32_t kind=0;uint64_t model=0,clump=0;uint8_t type=0;
            if(!s.vehicle)return @"Сначала сядь в транспорт";
            if(!vehicleRef(s.base,s.vehicle,ref)||!read(s.vehicle+0x398,hp)||!std::isfinite(hp)||hp<=0||!read(s.vehicle+0x430,kind)||kind!=0||
               !read(s.vehicle+0x728,model)||!model||!read(s.vehicle+0x68,clump)||!clump||!read(clump,type)||type!=2||
               !anchorAt(s.base,0x944034,0xa9be4ff4U)||!sameLocal(s)||!liveVehicle(ref))return @"Ремонт этого транспорта пока не поддерживается";
            using Fix=void(*)(void *);
            reinterpret_cast<Fix>(s.base+0x944034)(reinterpret_cast<void *>(ref.net));
            if(liveVehicle(ref)){const float full=1000;(void)writeData(s.vehicle+0x398,full);}
            lastAction=now;return @"Локальная команда ремонта выполнена";
        }
        if([action isEqualToString:@"heal"]||[action isEqualToString:@"armor"]||[action isEqualToString:@"healVehicle"]) {
            bool car=[action isEqualToString:@"healVehicle"],armor=[action isEqualToString:@"armor"];
            if(car&&!s.vehicle)return @"Сначала сядь в транспорт";
            uint32_t code=0;
            const uint64_t anchor=car?0x943f04:0x9c394c;
            if(!read(s.base+anchor,code)||code!=(car?0xbd039900U:0xbd04b260U))return @"Поле здоровья не прошло проверку";
            const uint64_t entity=car?s.vehicle:s.ped,offset=car?0x398:(armor?0x4b8:0x4b0);
            float current=0;
            if(!read(entity+offset,current)||!std::isfinite(current)||current<0||current>10000||!sameLocal(s))return @"Объект недоступен";
            if(car&&current<=0)return @"Разрушенный транспорт не восстанавливается этой командой";
            if(!car) {float hp=0;if(!read(s.ped+0x4b0,hp)||!std::isfinite(hp)||hp<=0)return @"Персонаж уже погиб";}
            const float full=std::max(current,car?1000.0f:100.0f);
            if(!writeData(entity+offset,full))return @"Не удалось восстановить значение";
            lastAction=now;
            return car?@"HP транспорта восстановлено локально":(armor?@"Броня восстановлена локально":@"HP восстановлено локально");
        }
        if([action isEqualToString:@"dash"]) {
            if(s.vehicle)return @"Для рывка выйди из транспорта";
            Matrix camera{};
            if(!read(s.base+0x22892a0+0x900,camera))return @"Камера недоступна";
            const float x=camera.v[2],y=camera.v[6],length=std::hypot(x,y);
            const double power=values[@"power"].doubleValue;
            if(!std::isfinite(length)||length<0.001||!std::isfinite(power)||power<1||power>5||!sameLocal(s))return @"Рывок недоступен";
            V3 speed{static_cast<float>(x/length*0.15*power),static_cast<float>(y/length*0.15*power),s.velocity.z};
            if(!writeData(s.ped+0x180,speed))return @"Не удалось выполнить рывок";
            lastAction=now;return @"Рывок по направлению камеры";
        }
        if([action isEqualToString:@"hop"]) {
            if(s.vehicle)return @"Для прыжка выйди из транспорта";
            double power=values[@"power"].doubleValue;
            if(!std::isfinite(power)||power<1||power>5)return @"Сила прыжка: 1–5";
            float vertical=static_cast<float>(0.18*power);
            if(!sameLocal(s)||!writeData(s.ped+0x188,vertical))return @"Не удалось задать прыжок";
            lastAction=now;return @"Задан вертикальный импульс";
        }
        if([action isEqualToString:@"massPed"]||[action isEqualToString:@"massVehicle"]||[action isEqualToString:@"massReset"]) {
            if([action isEqualToString:@"massReset"]) {
                bool a=restoreMass(s,pedMass,s.ped),b=restoreMass(s,vehicleMass,s.vehicle);
                return a&&b?@"Исходная масса восстановлена":@"Объект сменился: прежнюю массу восстановить не удалось";
            }
            bool car=[action isEqualToString:@"massVehicle"];
            const uint64_t entity=car?s.vehicle:s.ped;
            if(!entity)return @"Сначала сядь в транспорт";
            const double factor=values[@"factor"].doubleValue;
            if(!std::isfinite(factor)||factor<0.1||factor>5)return @"Множитель массы: 0.1–5";
            float current=0;
            if(!read(entity+0x1c8,current)||!std::isfinite(current)||current<0.1||current>1e7||!sameLocal(s))return @"Масса объекта недоступна";
            MassBackup &backup=car?vehicleMass:pedMass;
            if(backup.entity!=entity||backup.ped!=s.ped||backup.local!=s.local||backup.id!=s.id)
                backup={entity,s.ped,s.local,current,s.id};
            const float mass=static_cast<float>(std::clamp(backup.original*factor,0.1,1e7));
            if(!writeData(entity+0x1c8,mass))return @"Не удалось изменить массу";
            lastAction=now;return @"Масса изменена локально";
        }
        if([action isEqualToString:@"boostVehicle"]) {
            if(!s.vehicle)return @"Сначала сядь в транспорт";
            double factor=values[@"factor"].doubleValue;V3 speed{};
            if(!std::isfinite(factor)||factor<1||factor>3||!read(s.vehicle+0x180,speed)||!finite(speed)||!sameLocal(s))return @"Ускорение недоступно";
            double length=std::hypot(speed.x,speed.y);
            if(length<0.01)return @"Сначала начни движение";
            double scale=std::min(factor,3.0/length);
            if(scale<1)return @"Достигнут предел ускорения";
            speed.x*=scale;speed.y*=scale;
            if(!writeData(s.vehicle+0x180,speed))return @"Не удалось изменить скорость";
            lastAction=now;return @"Горизонтальная скорость транспорта увеличена";
        }
        if([action isEqualToString:@"flipVehicle"]) {
            if(!s.vehicle)return @"Сначала сядь в транспорт";
            Matrix matrix{};
            if(!read(s.vehicle+8,matrix)||!sameLocal(s))return @"Матрица транспорта недоступна";
            for(int row=0;row<3;++row) {
                V3 axis{matrix.v[row*4],matrix.v[row*4+1],matrix.v[row*4+2]};
                float length=std::sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z);
                if(!finite(axis)||length<0.3f||length>3)return @"Матрица ориентации не прошла проверку";
            }
            float x=matrix.v[4],y=matrix.v[5],length=std::hypot(x,y);
            if(!std::isfinite(length)||length<0.001) {x=0;y=1;length=1;}
            x/=length;y/=length;
            V3 right{y,-x,0},forward{x,y,0},up{0,0,1},zero{};const uint8_t dirty=1;
            if(!writeData(s.vehicle+0x180,zero)||!writeData(s.vehicle+8,right)||!writeData(s.vehicle+0x18,forward)||
               !writeData(s.vehicle+0x28,up)||!writeData(s.vehicle+0x60,dirty))return @"Не удалось выровнять транспорт";
            lastAction=now;return @"Матрица транспорта выровнена по вертикали";
        }
        if([action isEqualToString:@"stopVehicle"]) {
            if(!s.vehicle)return @"Сначала сядь в транспорт";
            uint64_t vehicle=0;V3 speed{};
            if(!sameLocal(s)||!read(s.ped+0x540,vehicle)||vehicle!=s.vehicle||
               !read(vehicle+0x180,speed)||!finite(speed))return @"Транспорт сменился или недоступен";
            V3 zero{};
            if(!writeData(vehicle+0x180,zero))return @"Не удалось остановить транспорт";
            lastAction=now;return @"Линейная скорость транспорта обнулена локально";
        }
        return @"Команда не поддерживается";
    }
}
+ (NSString *)status { std::lock_guard<std::mutex> lock(statusMutex);return lastStatus; }
+ (NSArray<NSNumber *> *)projectionMatrix {
    // Independent from the slow collector's lock: one 64-byte copy per frame.
    const uint64_t base=verifiedProjectionBase.load(std::memory_order_acquire);
    Matrix camera{};
    if(!base||!read(base+0x22892a0+0x900,camera))return @[];
    double magnitude=0;
    for(float value:camera.v) {if(!std::isfinite(value))return @[];magnitude+=std::abs(value);}
    if(magnitude<0.001)return @[];
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:16];
    for(float value:camera.v)[result addObject:@(value)];
    return result;
}
+ (NSArray<NSDictionary<NSString *,id> *> *)snapshotIgnoringRenderFlags:(BOOL)ignoreRenderFlags maxDistance:(double)maxDistance {
    { std::lock_guard<std::mutex> lock(collectorMutex);
    @autoreleasepool {
        uint64_t base=imageBase();if(!base)return @[];
        uint32_t slotCode=0,healthCode=0;
        if(!read(base+0x94aef8,slotCode)||slotCode!=0x71177c3fU||!read(base+0x96cd1c,healthCode)||healthCode!=0xbd414800U) {
            setStatus(@"ESP отключён: контрольные инструкции не совпадают");return @[];
        }
        uint64_t pool=0;
        if(!read(base+0x340de18,pool)||!pool){setStatus(@"Ожидание пула игроков");return @[];}
        std::array<uint64_t,1504> players{};
        if(!copy(pool+8,players.data(),sizeof(players))){setStatus(@"Пул игроков недоступен");return @[];}
        uint8_t activeCamera=0;V3 cameraPosition{};
        const bool hasCameraPosition=read(base+0x22892a0+0x94,activeCamera)&&activeCamera<3&&
            read(base+0x22892a0+uint64_t(activeCamera)*0x1e8+0x334,cameraPosition)&&finite(cameraPosition);
        int32_t pluginOffset=0;
        const bool hasPlugin=read(base+0x3408860+4,pluginOffset)&&pluginOffset>=-0x10000&&pluginOffset<=0x10000;
        struct Shape {uint64_t ped=0;bool valid=false;V3 bone{},lo{},hi{};};
        static std::array<Shape,1504> shapes{};static uint64_t shapePool=0;
        if(shapePool!=pool){shapes={};shapePool=pool;}
        NSMutableArray *result=[NSMutableArray array];size_t streamed=0,approximate=0;
        std::array<AimActor,128> candidates{};size_t candidateCount=0;
        for(size_t slot=0;slot<players.size()&&result.count<128;++slot) {
            uint64_t remote=players[slot];if(!remote){shapes[slot]={};continue;}
            std::array<uint8_t,0x288> data{};
            if(!copy(remote,data.data(),data.size()))continue;
            const uint64_t ped=field<uint64_t>(data.data(),0x10);
            if(!ped||field<uint16_t>(data.data(),0x4a)!=slot||!data[0x120])continue;
            if(!ignoreRenderFlags&&(data[8]&1))continue;
            V3 root{};
            std::array<uint8_t,0x28> pedData{};
            if(!read(ped+0x38,root)||!finite(root)||!copy(ped+0x68,pedData.data(),pedData.size()))continue;
            if(!ignoreRenderFlags&&!(pedData[0x25]&4))continue;
            ++streamed;
            double distance=-1;
            if(hasCameraPosition) {
                double dx=root.x-cameraPosition.x,dy=root.y-cameraPosition.y,dz=root.z-cameraPosition.z;
                distance=std::sqrt(dx*dx+dy*dy+dz*dz);
                if(std::isfinite(maxDistance)&&maxDistance>=25&&distance>maxDistance+5)continue;
            }
            Shape &shape=shapes[slot];if(shape.ped!=ped){shape={};shape.ped=ped;}
            // World-space extents, relative to the current physical actor root.
            // Never publish old screen-space coordinates from the worker.
            bool fresh=false;
            const uint64_t clump=field<uint64_t>(pedData.data(),0);
            std::array<uint8_t,0x18> clumpData{};
            if(hasPlugin&&clump&&copy(clump,clumpData.data(),clumpData.size())&&clumpData[0]==2) {
                const uint64_t link=field<uint64_t>(clumpData.data(),0x10);
                const int64_t address=int64_t(link)+pluginOffset-0x58;
                uint64_t hierarchy=0;
                std::array<uint8_t,0x10> hierarchyData{};
                if(link&&link!=clump+0x10&&address>=0x10000&&read(uint64_t(address),hierarchy)&&hierarchy&&copy(hierarchy,hierarchyData.data(),hierarchyData.size())) {
                    const int32_t nodes=field<int32_t>(hierarchyData.data(),4);
                    const uint64_t matrices=field<uint64_t>(hierarchyData.data(),8);
                    std::array<Matrix,256> bones{};
                    if(nodes>=4&&nodes<=256&&matrices&&copy(matrices,bones.data(),size_t(nodes)*sizeof(Matrix))) {
                        V3 first{bones[0].v[12],bones[0].v[13],bones[0].v[14]};
                        // Offscreen animations may stop updating bone matrices.
                        // Reuse actor-relative extents instead of following old bones.
                        const bool unchanged=shape.valid&&first.x==shape.bone.x&&first.y==shape.bone.y&&first.z==shape.bone.z;
                        if(!unchanged) {
                            V3 lo{1e6f,1e6f,1e6f},hi{-1e6f,-1e6f,-1e6f};int valid=0;
                            for(int i=0;i<nodes;++i) {
                                V3 pos{bones[i].v[12],bones[i].v[13],bones[i].v[14]};if(!finite(pos))continue;
                                lo.x=std::min(lo.x,pos.x);lo.y=std::min(lo.y,pos.y);lo.z=std::min(lo.z,pos.z);
                                hi.x=std::max(hi.x,pos.x);hi.y=std::max(hi.y,pos.y);hi.z=std::max(hi.z,pos.z);++valid;
                            }
                            const V3 relLo{lo.x-root.x,lo.y-root.y,lo.z-root.z},relHi{hi.x-root.x,hi.y-root.y,hi.z-root.z};
                            if(valid>=4&&hi.z-lo.z>0.3f&&hi.z-lo.z<4&&hi.x-lo.x<4&&hi.y-lo.y<4&&
                               finite(relLo)&&finite(relHi)&&std::abs(relLo.x)<4&&std::abs(relHi.x)<4&&
                               std::abs(relLo.y)<4&&std::abs(relHi.y)<4&&std::abs(relLo.z)<4&&std::abs(relHi.z)<4) {
                                shape.lo=relLo;shape.hi=relHi;shape.valid=true;shape.bone=first;fresh=true;
                            }
                        }
                    }
                }
            }
            const bool approx=!shape.valid||!fresh;if(approx)++approximate;
            const V3 lo=shape.valid?shape.lo:V3{-0.35f,-0.35f,-1.0f};
            const V3 hi=shape.valid?shape.hi:V3{0.35f,0.35f,0.85f};
            uint64_t verify=0,verifyPed=0;
            if(!read(pool+8+slot*8,verify)||verify!=remote||!read(remote+0x10,verifyPed)||verifyPed!=ped)continue;
            const float health=field<float>(data.data(),0x148),armor=field<float>(data.data(),0x14c);
            if(!std::isfinite(health)||!std::isfinite(armor)||health<0||health>10000||armor<0||armor>10000)continue;
            char nick[50]={0};std::memcpy(nick,data.data()+0x18,49);
            NSString *name=[[NSString alloc] initWithUTF8String:nick];
            if(!name)name=[[NSString alloc] initWithBytes:nick length:strnlen(nick,49) encoding:NSWindowsCP1251StringEncoding];
            if(!name.length)name=@"Player";
            AimActor candidate{};candidate.ped=ped;candidate.remote=remote;candidate.id=uint16_t(slot);candidate.root=root;candidate.hp=health;
            candidate.offset={(lo.x+hi.x)/2,(lo.y+hi.y)/2,lo.z+(hi.z-lo.z)*0.68f};
            candidate.head={(lo.x+hi.x)/2,(lo.y+hi.y)/2,hi.z-0.10f};
            if(read(ped+0x4b0,candidate.physicalHP)&&read(ped+0x494,candidate.state)&&candidateCount<candidates.size()) {
                NSString *folded=[name lowercaseString];const char *utf8=folded.UTF8String;
                if(utf8)std::strncpy(candidate.nick.data(),utf8,candidate.nick.size()-1);
                candidates[candidateCount++]=candidate;
            }
            [result addObject:@{@"id":@(slot),@"name":name,@"hp":@(health),@"armor":@(armor),@"distance":@(distance),@"approx":@(approx),
                @"bounds":@[@(root.x+lo.x),@(root.y+lo.y),@(root.z+lo.z),@(root.x+hi.x),@(root.y+hi.y),@(root.z+hi.z)]}];
        }
        {std::lock_guard<std::mutex> lock(aimMutex);aimActors=candidates;aimCount=candidateCount;aimReceived=NSProcessInfo.processInfo.systemUptime;}
        setStatus([NSString stringWithFormat:@"ESP: %lu · кэш формы %zu · камера каждый кадр",(unsigned long)result.count,approximate]);
        return result;
    }
    }
}
@end
