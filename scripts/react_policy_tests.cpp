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
    std::cout<<"FOV, clock packing, weather bounds and disabled fallbacks passed\n";
}
