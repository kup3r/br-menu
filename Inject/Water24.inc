std::atomic<bool> waterWalk24{false};
bool waterBridge24(uint64_t base) {
    if(!base)return false;
    std::array<uint32_t,6> marker{};uint32_t call=0;
    return copy(base+0x353c000,marker.data(),sizeof(marker))&&marker[0]==0x43414552U&&marker[1]==0x00343254U&&
        marker[2]==1&&marker[3]==0x99adac&&marker[4]==0x353c100&&marker[5]==0x99a54c&&
        read(base+0x99adac,call)&&call==(0x94000000U|uint32_t((0x353c100-0x99adac)/4));
}
uint32_t waterDecision24(uint64_t ped) {
    if(!waterWalk24.load()||![NSThread isMainThread])return 1;
    Local s;if(!liveConnected(s)||s.vehicle||ped!=s.ped)return 1;
    if(!anchorAt(s.base,0x99a54c,0xd10183ffU)||!anchorAt(s.base,0xa867d8,0xf9400801U))return 1;
    uint32_t flags=0;uint64_t intelligence=0;
    if(!read(s.ped+0x8c,flags)||!read(s.ped+0x798,intelligence)||!intelligence)return 1;
    // The native dry branch clears touching-water, and asks an existing swim
    // task to finish by setting its stop-time to 1000 (99a678..99a694).
    flags&=~0x04000000U;if(!writeData(s.ped+0x8c,flags))return 1;
    using Find=void *(*)(void *);void *task=reinterpret_cast<Find>(s.base+0xa867d8)(reinterpret_cast<void *>(intelligence));
    if(task){const float finish=1000;(void)writeData(reinterpret_cast<uint64_t>(task)+0x68,finish);}
    return 0;
}
