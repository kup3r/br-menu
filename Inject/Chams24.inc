// Native RenderWare atomic callbacks. Verified in this client:
// Atomic::create 8c0df4 writes renderCB at +70, geometry is +28;
// the clump list link is +58 and the owner clump is +50.
using AtomicRender24=void(*)(void *,uint64_t);
struct ChamsRecord24 {
    uint64_t base=0,pool=0,remote=0,ped=0,clump=0,atomic=0,geometry=0,original=0;
    uint16_t id=0;uint64_t seen=0;bool active=false;
};
std::mutex chamsMutex24;
std::unordered_map<uint64_t,ChamsRecord24> chamsRecords24;
std::atomic<bool> chamsEnabled24{false},chamsWalls24{true};
std::atomic<uint32_t> chamsColor24{0xffe6c419U};
std::atomic<uint64_t> chamsDraws24{0};
std::atomic<uint32_t> chamsActive24{0};
double chamsDistance24=150,chamsRefresh24=0;
void renderChams24(void *,uint64_t) noexcept;
uint64_t chamsCallback24(){return reinterpret_cast<uint64_t>(&renderChams24);}
bool liveChams24(const ChamsRecord24 &r) {
    uint64_t pool=0,remote=0,ped=0,clump=0,owner=0,geometry=0;
    return read(r.base+0x340de18,pool)&&pool==r.pool&&
        read(pool+8+uint64_t(r.id)*8,remote)&&remote==r.remote&&
        read(remote+0x10,ped)&&ped==r.ped&&read(ped+0x68,clump)&&clump==r.clump&&
        read(r.atomic+0x50,owner)&&owner==r.clump&&read(r.atomic+0x28,geometry)&&geometry==r.geometry;
}
// Return true once no callback owned by this record remains installed.
bool detachChams24(ChamsRecord24 &r) {
    r.active=false;uint64_t callback=0;
    if(!read(r.atomic+0x70,callback)||callback!=chamsCallback24())return true;
    return liveChams24(r)&&writeData(r.atomic+0x70,r.original);
}
void stopChams24() {
    chamsEnabled24.store(false);
    std::lock_guard<std::mutex> lock(chamsMutex24);
    for(auto i=chamsRecords24.begin();i!=chamsRecords24.end();){if(detachChams24(i->second))i=chamsRecords24.erase(i);else ++i;}
    chamsActive24.store(0);chamsRefresh24=0;
}
struct MaterialBackup24 {uint64_t address=0,texture=0;uint32_t rgba=0;std::array<float,3> surface{};};
void renderChams24(void *object,uint64_t flags) noexcept {
    const uint64_t atomic=reinterpret_cast<uint64_t>(object);
    ChamsRecord24 r{};bool found=false;
    {std::lock_guard<std::mutex> lock(chamsMutex24);auto i=chamsRecords24.find(atomic);if(i!=chamsRecords24.end()){r=i->second;found=true;}}
    const uint64_t base=verifiedProjectionBase.load();
    const uint64_t original=found?r.original:(base?base+0x8c0ec0:0);
    if(!original||original==chamsCallback24())return;
    const auto draw=reinterpret_cast<AtomicRender24>(original);
    static thread_local bool drawing=false;
    if(drawing||!found||!r.active||!chamsEnabled24.load()||![NSThread isMainThread]||![EAGLContext currentContext]||!liveChams24(r)){draw(object,flags);return;}
    uint32_t geometryFlags=0;int32_t count=0;uint64_t materials=0;
    if(!read(r.geometry+0x10,geometryFlags)||!read(r.geometry+0x80,materials)||!materials||
       !read(r.geometry+0x88,count)||count<1||count>64){draw(object,flags);return;}
    std::array<uint64_t,64> pointers{};
    if(!copy(materials,pointers.data(),size_t(count)*8)){draw(object,flags);return;}
    std::array<MaterialBackup24,64> backup{};size_t saved=0;
    for(int i=0;i<count;++i){
        const uint64_t address=pointers[i];if(!address)continue;
        bool duplicate=false;for(size_t j=0;j<saved;++j)if(backup[j].address==address)duplicate=true;
        if(duplicate)continue;
        MaterialBackup24 m{};m.address=address;
        if(!read(address,m.texture)||!read(address+8,m.rgba)||!read(address+12,m.surface)){draw(object,flags);return;}
        bool finiteSurface=true;for(float value:m.surface)if(!std::isfinite(value)||std::abs(value)>100)finiteSurface=false;
        if(!finiteSurface){draw(object,flags);return;}backup[saved++]=m;
    }
    if(!saved){draw(object,flags);return;}
    const GLboolean depthTest=glIsEnabled(GL_DEPTH_TEST);GLboolean depthWrite=GL_TRUE;glGetBooleanv(GL_DEPTH_WRITEMASK,&depthWrite);
    drawing=true;
    const uint32_t color=chamsColor24.load();const uint64_t noTexture=0;const std::array<float,3> fullbright{1,0,0};
    const uint32_t ownedMask=0x60,desiredFlags=(geometryFlags&~0x20U)|0x40U;
    bool changed=writeData(r.geometry+0x10,desiredFlags);
    for(size_t i=0;i<saved&&changed;++i){const auto &m=backup[i];changed=writeData(m.address,noTexture)&&writeData(m.address+8,color)&&writeData(m.address+12,fullbright);}
    if(changed&&chamsWalls24.load()){glDisable(GL_DEPTH_TEST);glDepthMask(GL_FALSE);}
    if(!changed){
        for(size_t i=0;i<saved;++i){const auto &m=backup[i];(void)writeData(m.address,m.texture);(void)writeData(m.address+8,m.rgba);(void)writeData(m.address+12,m.surface);}
        (void)writeData(r.geometry+0x10,geometryFlags);
    }
    draw(object,flags);
    if(changed){
        for(size_t i=0;i<saved;++i){const auto &m=backup[i];(void)writeData(m.address,m.texture);(void)writeData(m.address+8,m.rgba);(void)writeData(m.address+12,m.surface);}
        uint32_t current=0;if(read(r.geometry+0x10,current)){current=(current&~ownedMask)|(geometryFlags&ownedMask);(void)writeData(r.geometry+0x10,current);}
        chamsDraws24.fetch_add(1);
    }
    glDepthMask(depthWrite);if(depthTest)glEnable(GL_DEPTH_TEST);else glDisable(GL_DEPTH_TEST);
    drawing=false;
}
void tickChams24() {
    if(!chamsEnabled24.load())return;
    const double now=NSProcessInfo.processInfo.systemUptime;if(now-chamsRefresh24<0.2)return;chamsRefresh24=now;
    Local local;int32_t state=0;
    if(!getLocal(local)||!read(local.base+0x340de10,state)||state!=14)return;
    if(!anchorAt(local.base,0x8c0df4,0xa9077e68U)||!anchorAt(local.base,0x8c0f28,0xf9401400U))return;
    std::array<uint64_t,1504> players{};if(!copy(local.pool+8,players.data(),sizeof(players)))return;
    static uint64_t generation=0;const uint64_t seen=++generation;size_t actors=0;
    std::lock_guard<std::mutex> lock(chamsMutex24);
    for(size_t id=0;id<players.size()&&actors<128;++id){
        if(id==local.id||!players[id])continue;
        uint64_t ped=0,clump=0,link=0;uint8_t type=0,streamed=0;V3 root{};
        if(!read(players[id]+0x120,streamed)||!streamed||!read(players[id]+0x10,ped)||!ped||!read(ped+0x38,root)||!finite(root))continue;
        const double dx=root.x-local.position.x,dy=root.y-local.position.y,dz=root.z-local.position.z;
        if(dx*dx+dy*dy+dz*dz>chamsDistance24*chamsDistance24||!read(ped+0x68,clump)||!clump||!read(clump,type)||type!=2||!read(clump+0x10,link))continue;
        ++actors;std::array<uint64_t,16> visited{};size_t visits=0;
        while(link&&link!=clump+0x10&&visits<visited.size()){
            bool duplicate=false;for(size_t j=0;j<visits;++j)if(visited[j]==link)duplicate=true;if(duplicate)break;visited[visits++]=link;
            const uint64_t atomic=link-0x58;uint64_t next=0,owner=0,geometry=0,callback=0;
            if(link<0x10058||!read(link,next)||!read(atomic,type)||type!=1||!read(atomic+0x50,owner)||owner!=clump||
               !read(atomic+0x28,geometry)||!geometry||!read(atomic+0x70,callback)){link=next;continue;}
            auto existing=chamsRecords24.find(atomic);
            if(existing!=chamsRecords24.end()&&existing->second.ped==ped&&existing->second.clump==clump&&existing->second.geometry==geometry&&callback==chamsCallback24()){
                existing->second.seen=seen;existing->second.active=true;
            }else if(callback>=local.base+0x4000&&callback<local.base+0x1257000&&chamsRecords24.size()<512){
                ChamsRecord24 r{local.base,local.pool,players[id],ped,clump,atomic,geometry,callback,uint16_t(id),seen,true};
                chamsRecords24[atomic]=r;if(!writeData(atomic+0x70,chamsCallback24()))chamsRecords24.erase(atomic);
            }
            link=next;
        }
    }
    uint32_t active=0;
    for(auto i=chamsRecords24.begin();i!=chamsRecords24.end();){
        if(i->second.seen!=seen){if(detachChams24(i->second)){i=chamsRecords24.erase(i);continue;}}
        if(i->second.active)++active;++i;
    }
    chamsActive24.store(active);
}
