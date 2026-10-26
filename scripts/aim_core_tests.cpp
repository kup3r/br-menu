#include "../Inject/AimMath.hpp"
#include <cassert>
#include <iostream>
#include <random>
using namespace BRAim;
static Candidate actor(unsigned id,double x,double y=0) {return {id,{x,y,0},100,100,0,false};}
int main() {
    assert(projectionRatio(2.0f,1.0f)==2.0f);assert(projectionRatio(2.0f,1.25f)==1.6f);
    assert(projectionRatio(.56f,1.5f)==.56f);assert(projectionRatio(2.0f,0)==2.0f);assert(projectionRatio(2.0f,NAN)==2.0f);
    View v;v.width=1000;v.height=600;v.radius=100;v.m[0]=.01f;v.m[5]=.01f;v.m[12]=.5f;v.m[13]=.5f;v.m[14]=1;
    Vec own{0,0,0};
    std::array<Candidate,8> a{actor(7,8),actor(2,3),actor(3,1),actor(4,0),actor(5,0),actor(6,0),actor(0,0),actor(1504,0)};
    a[2].excluded=true;a[3].state=52;a[4].state=53;a[5].hp=0;
    auto pick=choose(v,own,100,0,a.data(),a.size());assert(pick.found&&pick.id==2);
    a[1].physicalHP=0;pick=choose(v,own,100,0,a.data(),a.size());assert(pick.found&&pick.id==7);
    a[0].excluded=true;assert(!choose(v,own,100,0,a.data(),a.size()).found);
    a={actor(2,5),actor(1,-5)};pick=choose(v,own,100,0,a.data(),2);assert(pick.found&&pick.id==1);
    std::swap(a[0],a[1]);pick=choose(v,own,100,0,a.data(),2);assert(pick.found&&pick.id==1);
    assert(!choose(v,own,4,0,a.data(),2).found);
    assert(!choose(v,own,NAN,0,a.data(),2).found);
    assert(!choose(v,own,100,0,nullptr,2).found);
    assert(!choose(v,own,100,0,a.data(),129).found);
    a[0]=actor(9,9);v.stretch=1.5;assert(!choose(v,own,100,0,a.data(),1).found);
    v.stretch=1;assert(choose(v,own,100,0,a.data(),1).found);
    v.m[14]=-1;assert(!choose(v,own,100,0,a.data(),1).found);v.m[14]=1;
    a[0].point.x=NAN;assert(!choose(v,own,100,0,a.data(),1).found);
    assert(living(100,100,0)&&!living(0,100,0)&&!living(100,0,0)&&!living(100,100,52)&&!living(100,100,53));
    unsigned miss0=0,miss37=0,miss100=0;
    for(unsigned r=0;r<10000;++r){miss0+=skip(r,0);miss37+=skip(r,37);miss100+=skip(r,100);}
    assert(miss0==0&&miss37==3700&&miss100==10000);
    Vec output{};assert(!endpoint(own,own,{1,0,0},output));assert(!endpoint(own,{10,0,0},{100,0,0},output));
    std::mt19937 gen(16);std::uniform_real_distribution<double> random(-30,30);
    for(unsigned i=0;i<10000;++i) {
        Vec start{random(gen),random(gen),random(gen)};
        Vec target{start.x+1+std::abs(random(gen)),start.y+random(gen),start.z+random(gen)};
        assert(endpoint(start,{start.x+500,start.y,start.z},target,output));
        Vec d{output.x-start.x,output.y-start.y,output.z-start.z},t{target.x-start.x,target.y-start.y,target.z-start.z};
        assert(std::abs(std::sqrt(d.x*d.x+d.y*d.y+d.z*d.z)-500)<1e-8);
        assert(std::abs(d.x*t.y-d.y*t.x)<1e-7&&std::abs(d.y*t.z-d.z*t.y)<1e-7);
    }
    std::cout<<"PASS: production target selection (self/death/HP/exclusions/FOV/range/ties), 10000 ray invariants, exact skip thresholds\n";
}
