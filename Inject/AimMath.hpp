#pragma once
#include <array>
#include <cmath>
#include <algorithm>
#include <cstddef>
#include <limits>
namespace BRAim {
struct Vec {double x=0,y=0,z=0;};
struct View {std::array<float,16> m{};double width=0,height=0,stretch=1,radius=100;};
inline float projectionRatio(float natural,float scale) {
    if(!std::isfinite(natural)||natural<1||!std::isfinite(scale)||scale<1||scale>1.6f)return natural;
    return natural/scale;
}
inline bool valid(Vec p) {return std::isfinite(p.x)&&std::isfinite(p.y)&&std::isfinite(p.z)&&std::abs(p.x)<100000&&std::abs(p.y)<100000&&std::abs(p.z)<100000;}
inline bool living(double hp,double physicalHP,unsigned state) {
    return std::isfinite(hp)&&std::isfinite(physicalHP)&&hp>0&&physicalHP>0&&hp<=10000&&physicalHP<=10000&&state!=52&&state!=53;
}
inline bool project(const View &v,Vec p,double &x,double &y) {
    if(!valid(p)||!std::isfinite(v.width)||!std::isfinite(v.height)||!std::isfinite(v.stretch)||v.width<=0||v.height<=0||v.stretch<1||v.stretch>1.6)return false;
    auto &m=v.m;const double z=m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14];
    if(!std::isfinite(z)||z<=0.05)return false;
    x=.5+((m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12])/z-.5)*v.stretch;
    y=(m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13])/z;
    return std::isfinite(x)&&std::isfinite(y)&&x>=0&&x<=1&&y>=0&&y<=1;
}
inline double score(const View &v,Vec p) {
    double x=0,y=0;if(!project(v,p,x,y)||!std::isfinite(v.radius)||v.radius<1)return -1;
    const double dx=(x-.5)*v.width,dy=(y-.5)*v.height,d=dx*dx+dy*dy;
    return d<=v.radius*v.radius?d:-1;
}
struct Candidate {unsigned id=0;Vec point{};double hp=0,physicalHP=0;unsigned state=0;bool excluded=false;};
struct Selection {std::size_t index=0;bool found=false;double squaredDistance=0;unsigned id=0;};
inline Selection choose(const View &view,Vec own,double range,unsigned ownID,const Candidate *actors,std::size_t count) {
    Selection selected{};
    if(!actors||!valid(own)||!std::isfinite(range)||range<=0||range>10000||count>128)return selected;
    double best=std::numeric_limits<double>::infinity();
    for(std::size_t i=0;i<count;++i) {
        const Candidate &a=actors[i];
        if(a.id>=1504||a.id==ownID||a.excluded||!living(a.hp,a.physicalHP,a.state)||!valid(a.point))continue;
        const double dx=a.point.x-own.x,dy=a.point.y-own.y,dz=a.point.z-own.z;
        if(dx*dx+dy*dy+dz*dz>range*range)continue;
        const double value=score(view,a.point);
        if(value>=0&&(value<best||(value==best&&a.id<selected.id))) {
            best=value;selected={i,true,value,a.id};
        }
    }
    return selected;
}
inline bool endpoint(Vec from,Vec original,Vec target,Vec &out) {
    if(!valid(from)||!valid(original)||!valid(target))return false;
    const Vec a{original.x-from.x,original.y-from.y,original.z-from.z},d{target.x-from.x,target.y-from.y,target.z-from.z};
    const double range=std::sqrt(a.x*a.x+a.y*a.y+a.z*a.z),distance=std::sqrt(d.x*d.x+d.y*d.y+d.z*d.z);
    if(!std::isfinite(range)||!std::isfinite(distance)||range<.1||distance<.1||distance>range+1)return false;
    const double scale=range/distance;out={from.x+d.x*scale,from.y+d.y*scale,from.z+d.z*scale};return valid(out);
}
inline bool skip(unsigned random10000,double missPercent) {return random10000<std::clamp(missPercent,0.0,100.0)*100;}
}
