#include "../Inject/ReactPolicies.hpp"
#include <cassert>
#include <limits>
#include <iostream>
int main(){
    using namespace React19;
    assert(fov(73,0)==73);assert(fov(73,49)==73);assert(fov(73,121)==73);
    assert(fov(73,std::numeric_limits<float>::quiet_NaN())==73);
    assert(fov(73,std::numeric_limits<float>::infinity())==73);
    assert(fov(73,50)==50);assert(fov(73,120)==120);
    for(uint32_t hour=0;hour<256;++hour)for(uint32_t minute=0;minute<256;++minute){
        assert(clock(hour,minute,-1,-1)==(uint64_t(hour)|(uint64_t(minute)<<32)));
        assert(clock(hour,minute,23,59)==(uint64_t(23)|(uint64_t(59)<<32)));
    }
    assert(clock(12,10,24,0)==(uint64_t(12)|(uint64_t(10)<<32)));
    for(int value=-2;value<24;++value)assert(weather(4,value)==uint32_t(value>=0&&value<=21?value:4));
    float x=0,y=0;
    assert(runStep(0.2f,0,0.1f,0,0.05,2,x,y)&&std::abs(x-0.2f)<0.00001f&&y==0);
    // Last position is measured after the previous adjustment: base displacement stays constant.
    float position=0,after=0;
    for(int i=0;i<100;++i){position=after+0.2f;assert(runStep(position-after,0,0.1f,0,0.05,2,x,y));after=position+x;}
    assert(std::abs(after-40)<0.001);
    assert(!runStep(10,0,0.1f,0,0.05,2,x,y)); // teleport/server correction
    assert(!runStep(0,0,0.1f,0,0.05,2,x,y)); // idle
    assert(!runStep(-0.1f,0,0.1f,0,0.05,2,x,y)); // collision correction opposing movement
    assert(!runStep(0.2f,0,0,0,0.05,2,x,y));
    // A wrapped yaw takes the short path and smoothing is independent of 30/60 Hz.
    float a=0,b=0;
    assert(React21::cameraStep(0,3.13,1,0.01,0,1.0/60,0.2,a,b));
    assert(std::remainder(double(b)-3.13,2*3.141592653589793)>0 && std::remainder(double(b)-3.13,2*3.141592653589793)<0.01);
    float a30=0,b30=0,a60=0,b60=0;
    for(int i=0;i<30;++i)assert(React21::cameraStep(a30,b30,10,10,3,1.0/30,0.3,a30,b30));
    for(int i=0;i<60;++i)assert(React21::cameraStep(a60,b60,10,10,3,1.0/60,0.3,a60,b60));
    assert(std::abs(a30-a60)<0.00001&&std::abs(b30-b60)<0.00001);
    assert(!React21::cameraStep(0,0,0,0,0,1.0/60,0.2,a,b));
    assert(!React21::cameraStep(0,0,1,1,1,1.0/60,0,a,b));
    // A changed aspect retains the same effective vertical framing.
    constexpr double rad=3.14159265358979323846/180;
    for(float degrees:{50.f,70.f,100.f,120.f})for(float scale:{1.f,1.2f,1.6f}) {
        const double compensated=React22::stretchFOV(degrees,scale);
        assert(std::abs(std::tan(compensated*rad/2)/scale-std::tan(degrees*rad/2))<0.000002);
    }
    assert(React22::stretchFOV(70,0)==70);
    float vx=0,vy=0,afterVX=0;
    for(int i=0;i<100;++i){
        vx=afterVX+0.001f;assert(React22::acceleration(afterVX,0,vx,0,1,0,0.05,5,x,y));afterVX=vx+x;
    }
    assert(std::abs(afterVX-0.5f)<0.00001); // five times the native acceleration, no exponential feedback
    assert(!React22::acceleration(.5f,0,.4f,0,1,0,.05,5,x,y)); // braking untouched
    assert(!React22::acceleration(0,0,1,0,1,0,.05,5,x,y)); // correction/impact rejected
    assert(!React22::acceleration(0,0,0,.01f,1,0,.05,5,x,y)); // lateral movement untouched
    (void)vy;
    uint32_t flags[]={0,2,1,1};int16_t parents[4]{};
    assert(React22::boneParents(flags,4,parents));
    assert(parents[0]==-1&&parents[1]==0&&parents[2]==1&&parents[3]==0);
    uint32_t invalidFlags[]={1,0};assert(!React22::boneParents(invalidFlags,2,parents));
    React22::Medicine medicine;
    assert(medicine.due(100,10,20,35,15,true));
    assert(!medicine.due(110,10,20,35,15,true));
    assert(medicine.due(115,10,20,35,15,true));
    assert(!medicine.due(130,10,100,35,15,true));
    assert(!medicine.due(140,10,0,35,15,true));
    assert(medicine.due(141,11,20,35,15,true));
    std::cout<<"FOV, clock packing, weather bounds and disabled fallbacks passed\n";
}

