#pragma once
#include <cmath>
#include <cstdint>
namespace React19 {
inline float fov(float natural,float wanted) {return std::isfinite(wanted)&&wanted>=50&&wanted<=120?wanted:natural;}
inline uint64_t clock(uint32_t hour,uint32_t minute,int wantedHour,int wantedMinute) {
    if(wantedHour>=0&&wantedHour<=23&&wantedMinute>=0&&wantedMinute<=59){hour=uint32_t(wantedHour);minute=uint32_t(wantedMinute);}
    return uint64_t(hour)|(uint64_t(minute)<<32);
}
inline uint32_t weather(uint32_t natural,int wanted) {return wanted>=0&&wanted<=21?uint32_t(wanted):natural;}
}
