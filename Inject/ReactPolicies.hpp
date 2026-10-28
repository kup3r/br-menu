#pragma once
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
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

namespace React22 {
// The engine derives a second FOV from aspect. Compensate that conversion so
// changing horizontal aspect preserves the vertical framing.
inline float stretchFOV(float fov,float scale) {
    if(!std::isfinite(fov)||!std::isfinite(scale)||fov<1||fov>170||scale<1||scale>1.6f)return fov;
    constexpr double radians=3.14159265358979323846/180;
    return float(2*std::atan(std::tan(fov*radians/2)*scale)/radians);
}
inline bool acceleration(float previousX,float previousY,float currentX,float currentY,float forwardX,float forwardY,double elapsed,double factor,float &extraX,float &extraY) {
    extraX=extraY=0;
    for(float v:{previousX,previousY,currentX,currentY,forwardX,forwardY})if(!std::isfinite(v))return false;
    if(!std::isfinite(elapsed)||elapsed<=0||elapsed>0.1||!std::isfinite(factor)||factor<1||factor>5)return false;
    const double length=std::hypot(forwardX,forwardY);if(length<0.5||length>1.5)return false;
    const double fx=forwardX/length,fy=forwardY/length;
    const double before=previousX*fx+previousY*fy,after=currentX*fx+currentY*fy,delta=after-before;
    // Ignore reverse, braking, lateral collisions and abrupt corrections.
    if(before<-.005||after<0||delta<=0.00001||delta>elapsed*1.5||std::hypot(currentX-previousX,currentY-previousY)>elapsed*2||after>3)return false;
    const double extra=std::min(delta*(factor-1),std::max(0.,3-after));
    extraX=float(fx*extra);extraY=float(fy*extra);return extra>0;
}
// librw HAnim node flag 1 pops; flag 2 saves the previous parent (8dd1cc).
inline bool boneParents(const uint32_t *flags,std::size_t count,int16_t *parents) {
    if(!flags||!parents||count<1||count>256)return false;
    std::array<int16_t,256> stack{};std::size_t depth=0;int16_t parent=-1;
    for(std::size_t i=0;i<count;++i){
        parents[i]=parent;
        if(flags[i]&~3U)return false;
        if(flags[i]&2U)stack[depth++]=parent;
        if(flags[i]&1U){if(depth==0){if(i+1!=count)return false;parent=-1;}else parent=stack[--depth];}
        else parent=int16_t(i);
    }
    return depth==0;
}
struct Medicine {
    double last=-1e9;uint64_t owner=0;bool armed=true;
    bool due(double now,uint64_t identity,double hp,double threshold,double interval,bool enabled) {
        if(!enabled||!identity||!std::isfinite(hp)||hp<=0||hp>10000||!std::isfinite(now)){owner=0;armed=true;return false;}
        if(owner!=identity){owner=identity;last=now-interval;armed=true;}
        if(hp>threshold+5)armed=true;
        if(hp>threshold||now-last<interval)return false;
        last=now;armed=false;return true;
    }
};
}

namespace React21 {
inline bool cameraStep(double alpha,double beta,double dx,double dy,double dz,double elapsed,double smooth,float &outAlpha,float &outBeta) {
    if(!std::isfinite(alpha)||!std::isfinite(beta)||!std::isfinite(dx)||!std::isfinite(dy)||!std::isfinite(dz)||!std::isfinite(elapsed)||!std::isfinite(smooth)||elapsed<=0||elapsed>0.1||smooth<0.02||smooth>1)return false;
    const double horizontal=std::hypot(dx,dy);if(horizontal<0.001)return false;
    const double desiredAlpha=std::clamp(std::atan2(dz,horizontal),-1.4,0.75),desiredBeta=std::atan2(-dy,-dx);
    constexpr double pi=3.14159265358979323846;
    const double gain=-std::expm1(-elapsed/smooth),difference=std::remainder(desiredBeta-beta,2*pi);
    outAlpha=float(alpha+(desiredAlpha-alpha)*gain);outBeta=float(std::remainder(beta+difference*gain,2*pi));
    return std::isfinite(outAlpha)&&std::isfinite(outBeta);
}
}

