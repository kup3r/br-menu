#pragma once
#include <cmath>
#include <cstdint>
#include <algorithm>
namespace React19 {
inline float fov(float natural,float wanted) {return std::isfinite(wanted)&&wanted>=50&&wanted<=120?wanted:natural;}
inline uint64_t clock(uint32_t hour,uint32_t minute,int wantedHour,int wantedMinute) {
    if(wantedHour>=0&&wantedHour<=23&&wantedMinute>=0&&wantedMinute<=59){hour=uint32_t(wantedHour);minute=uint32_t(wantedMinute);}
    return uint64_t(hour)|(uint64_t(minute)<<32);
}
inline uint32_t weather(uint32_t natural,int wanted) {return wanted>=0&&wanted<=21?uint32_t(wanted):natural;}
inline bool runStep(float dx,float dy,float vx,float vy,double elapsed,double factor,float &outX,float &outY) {
    outX=outY=0;
    if(!std::isfinite(dx)||!std::isfinite(dy)||!std::isfinite(vx)||!std::isfinite(vy)||!std::isfinite(elapsed)||!std::isfinite(factor)||elapsed<=0||elapsed>0.25||factor<1||factor>3)return false;
    const double distance=std::hypot(dx,dy),speed=std::hypot(vx,vy);
    if(distance<0.001||distance>std::max(0.5,elapsed*15)||speed<0.005||double(dx)*vx+double(dy)*vy<=0)return false;
    outX=float(dx*(factor-1));outY=float(dy*(factor-1));return true;
}
}
