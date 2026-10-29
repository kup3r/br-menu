std::atomic<double> damageFactor24{1};
// This modifies the verified damage definition only while processing one own
// bullet impact. The server can still validate or replace the resulting damage.
struct DamageScope24 {
    uint64_t base=0,info=0;uint32_t before=0,applied=0;uint8_t weapon=0;bool active=false;
    static thread_local bool busy;
    DamageScope24(void *owner,void *victim,void *gun) {
        const double factor=damageFactor24.load();if(factor<=1||factor>5||busy||![NSThread isMainThread]||!victim)return;
        Local s;uint8_t type=0,id=255;float hp=0;uint32_t life=0;
        if(!liveConnected(s)||reinterpret_cast<uint64_t>(owner)!=s.ped||reinterpret_cast<uint64_t>(victim)==s.ped||
           !read(reinterpret_cast<uint64_t>(victim)+0x78,type)||(type&7)!=3||
           !read(reinterpret_cast<uint64_t>(victim)+0x4b0,hp)||!read(reinterpret_cast<uint64_t>(victim)+0x494,life)||!BRAim::living(hp,hp,life)||
           !read(reinterpret_cast<uint64_t>(gun),id)||id==0||id==255||!anchorAt(s.base,0xb0f558,0xbd403aE0U))return;
        const uint64_t definition=weaponDefinition(s.base,id);uint32_t amount=0;
        if(!definition||!read(definition+0x38,amount)||amount<1||amount>1000)return;
        base=s.base;info=definition;weapon=id;before=amount;applied=std::min(5000U,uint32_t(std::lround(amount*factor)));
        if(writeData(info+0x38,applied)){active=true;busy=true;}
    }
    ~DamageScope24(){if(!active)return;uint32_t current=0;if(weaponDefinition(base,weapon)==info&&read(info+0x38,current)&&current==applied)(void)writeData(info+0x38,before);busy=false;}
    DamageScope24(const DamageScope24 &)=delete;DamageScope24 &operator=(const DamageScope24 &)=delete;
};
thread_local bool DamageScope24::busy=false;
