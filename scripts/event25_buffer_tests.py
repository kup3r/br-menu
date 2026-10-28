from pathlib import Path
import subprocess,tempfile,os
root=Path(__file__).resolve().parents[1]
s=(root/'Inject/Event25.inc').read_text();helper=s[s.index('bool readEventText25'):s.index('void incomingEvent25')]
fixture=r'''
#include <array>
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>
#include <iostream>
std::vector<char> memory(16384);int reads=0;bool accessible=true;
bool copy(uint64_t a,void *out,size_t n){assert(a/4096==(a+n-1)/4096);++reads;if(!accessible||a<0x10000||a+n>0x14000)return false;std::memcpy(out,memory.data()+a-0x10000,n);return true;}
'''+helper+r'''
int main(){
 for(size_t offset:{size_t(0),size_t(4080),size_t(4095)})for(size_t length:{size_t(0),size_t(1),size_t(127),size_t(128),size_t(4095),size_t(4096)}){
  std::fill(memory.begin(),memory.end(),0);std::fill_n(memory.begin()+offset,length,'a');reads=0;
  std::array<char,4097> out{};size_t n=0;
  bool ok=readEventText25(reinterpret_cast<const char *>(0x10000+offset),out,n);
  assert(ok==(length>0&&length<4096));assert(n==length);assert(reads<=34);
 }
 accessible=false;std::array<char,4097> out{};size_t n=0;assert(!readEventText25(reinterpret_cast<const char *>(0x10000),out,n));
 std::cout<<"Bounded incoming text, page edges, size limits and unreadable memory passed\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(fixture)
 subprocess.run([os.environ.get('CXX','clang++'),'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
