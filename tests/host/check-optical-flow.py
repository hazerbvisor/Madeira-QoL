#!/usr/bin/env python3
"""Execute the exact Metal core on CPU textures; test admission and display deadlines.
This does not execute a Metal driver or validate physical display latency.
"""
from pathlib import Path
import json, os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
shader=(root/'app/Madeira/OpticalFlow.metal').read_text()
header=(root/'app/Madeira/OpticalFlowSource.h').read_text()
embedded=''.join(json.loads(line.strip().rstrip(';')) for line in header.splitlines() if line.strip().startswith('"'))
assert embedded==shader, 'embedded device shader must match tested source'
core=shader.split('// Core begin: host tests compile these exact functions with texture adapters.\n')[1].split('// Core end')[0]
adapter=r'''
#include <algorithm>
#include <cmath>
#include <cassert>
#include <memory>
#include <vector>
#include <cstdio>
#include "FrameInterpolationTiming.h"
using std::abs; using std::min;
template<class T> struct v2 {
 T x,y; v2(T a=0):x(a),y(a){} v2(T a,T b):x(a),y(b){}
 template<class U> explicit v2(v2<U> a):x(T(a.x)),y(T(a.y)){}
 v2 operator+(v2 b)const{return {x+b.x,y+b.y};}
 v2 operator-(v2 b)const{return {x-b.x,y-b.y};}
 v2 operator*(T b)const{return {x*b,y*b};}
 v2 operator/(v2 b)const{return {x/b.x,y/b.y};}
};
using int2=v2<int>; using uint2=v2<unsigned>; using float2=v2<float>;
struct float4 {float x,y,z,w;float4(float a=0,float b=0,float c=0,float d=0):x(a),y(b),z(c),w(d){}
 float4 operator+(float4 b)const{return {x+b.x,y+b.y,z+b.z,w+b.w};}
 float4 operator*(float b)const{return {x*b,y*b,z*b,w*b};}
};
int2 clamp(int2 a,int2 lo,int2 hi){return {std::clamp(a.x,lo.x,hi.x),std::clamp(a.y,lo.y,hi.y)};}
float length(float2 a){return std::sqrt(a.x*a.x+a.y*a.y);}
namespace access { enum mode {read,sample,write}; }
namespace coord { enum kind {normalized}; }
namespace address { enum kind {clamp_to_edge}; }
namespace filter { enum kind {linear}; }
struct sampler { constexpr sampler(coord::kind,address::kind,filter::kind){} };
template<class T,access::mode A> struct texture2d {
 unsigned width,height; std::shared_ptr<std::vector<float4>> pixels;
 texture2d(unsigned w,unsigned h):width(w),height(h),pixels(std::make_shared<std::vector<float4>>(w*h)){}
 template<access::mode B> texture2d(texture2d<T,B> b):width(b.width),height(b.height),pixels(b.pixels){}
 unsigned get_width()const{return width;} unsigned get_height()const{return height;}
 float4 read(uint2 p)const{return (*pixels)[p.y*width+p.x];}
 float4 at(int x,int y)const{return read(uint2(std::clamp(x,0,int(width)-1),std::clamp(y,0,int(height)-1)));}
 float4 sample(sampler,float2 p)const{
  float x=p.x*width-.5f,y=p.y*height-.5f;int ix=int(std::floor(x)),iy=int(std::floor(y));float a=x-ix,b=y-iy;
  return at(ix,iy)*((1-a)*(1-b))+at(ix+1,iy)*(a*(1-b))+at(ix,iy+1)*((1-a)*b)+at(ix+1,iy+1)*(a*b);
 }
};
'''
checks=r'''
float distance(float4 a,float4 b){return abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z);}
int main(){
 texture2d<float,access::read> previous(160,128),current(160,128),cut(160,128);
 unsigned seed=1234567;
 for(auto &p:*previous.pixels){seed=1664525*seed+1013904223;p=float4((seed&255)/255.f,((seed>>8)&255)/255.f,((seed>>16)&255)/255.f,1);}
 for(unsigned y=0;y<128;y++) for(unsigned x=0;x<160;x++) (*current.pixels)[y*160+x]=previous.at(int(x)-8,int(y)-4);
 auto f=of_match(previous,current,int2(72,64)),b=of_match(current,previous,int2(72,64));
 assert(f.x==8 && f.y==4 && b.x==-8 && b.y==-4 && f.z==0 && b.z==0);
 assert(of_confident(f,b));
 for(int y=32;y<96;y++)for(int x=32;x<128;x++){
  auto middle=of_midpoint(previous,current,int2(x,y),f,b);
  assert(distance(middle,previous.at(x-4,y-2))<.00001f);
 }
 auto still=of_match(previous,previous,int2(72,64));assert(still.x==0 && still.y==0);
 assert(distance(of_midpoint(previous,previous,int2(72,64),still,still),previous.at(72,64))<.00001f);
 auto uncertain=float4(8,4,.5,0);
 assert(!of_confident(uncertain,b));
 assert(distance(of_midpoint(previous,current,int2(72,64),uncertain,b),current.at(72,64))==0);
 assert(!of_confident(f,float4(8,4,0,0))); // inconsistent direction cannot warp
 assert(distance(of_midpoint(previous,current,int2(0,0),f,b),previous.at(0,0))<.00001f); // border clamps
 for(auto &p:*cut.pixels)p=float4(1,1,1,1);
 auto scene=of_match(previous,cut,int2(72,64));assert(scene.z>.08f);
 assert(!madeira_interpolation_confidence(100,40,60000,0));
 assert(madeira_interpolation_confidence(100,10,30000,0));
 assert(!madeira_interpolation_confidence(100,10,30000,1));
 assert(!madeira_interpolation_confidence(0,0,0,0));
 assert(!madeira_interpolation_confidence(100,101,0,0));
 for(int fps:{30,60}){
  MadeiraInterpolationTimes t,u;double half=.5/fps;
  assert(madeira_interpolation_times(10,0,fps,&t));assert(abs(t.native-t.generated-half)<1e-9);
  assert(madeira_interpolation_times(10+1./fps,t.native,fps,&u));assert(abs(u.generated-t.native-half)<1e-9);
  assert(!madeira_interpolation_times(u.generated+.001,t.native,fps,&u)); // no late catch-up burst
  assert(!madeira_interpolation_times(9,t.native,fps,&u)); // no unbounded future queue
 }
 MadeiraInterpolationTimes t;
 assert(!madeira_interpolation_times(NAN,0,30,&t));assert(!madeira_interpolation_times(10,-1,30,&t));
 assert(!madeira_interpolation_times(10,0,40,&t));assert(!madeira_interpolation_times(10,0,30,nullptr));
 double period;
 assert(madeira_interpolation_pair_period(1./20,30,0,&period) && abs(period-.05)<1e-9);
 assert(!madeira_interpolation_pair_period(1./20,30,1,&period)); // Auto still requires steady 30
 assert(madeira_interpolation_pair_period(.04,30,0,&period) && abs(period-.04)<1e-9);
 assert(madeira_interpolation_pair_period(.02,30,0,&period) && abs(period-1./30)<1e-9); // panel budget
 assert(!madeira_interpolation_pair_period(.1,30,0,&period)); // re-warm after a long pause
 assert(!madeira_interpolation_pair_period(.001,30,0,&period)); // no burst pairing
 assert(!madeira_interpolation_pair_period(NAN,30,0,&period));
 for(int fps:{30,60}) {
  double interval=1.5/fps;
  MadeiraInterpolationTimes first, late;
  assert(madeira_interpolation_variable_times(10,0,interval,fps,&first));
  assert(abs(first.native-first.generated-interval*.5)<1e-9);
  assert(madeira_interpolation_variable_times(10+2./fps,first.native,interval,fps,&late));
  assert(late.generated>=10+2./fps+.001 && late.native>first.native); // rebase late, don't catch up
  assert(!madeira_interpolation_variable_times(9,first.native,interval,fps,&late)); // no future backlog
  assert(!madeira_interpolation_variable_times(10,0,3./fps,fps,&late)); // bounded history
  assert(!madeira_interpolation_variable_times(10,0,NAN,fps,&late));
  double fallback=madeira_interpolation_fallback_time(10,first.native,fps);
  assert(fallback>first.native && abs(fallback-first.native-.5/fps)<1e-9);
  assert(madeira_interpolation_fallback_time(first.native+.001,first.native,fps)==0);
 }
 puts("PASS: exact shader core, confidence, strict Auto deadlines, uneven manual intervals, late rebase, display budget and ordered fallback");
}
'''
swift=r'''
import Foundation
var policy = OpticalFlowAdmission()
func tick(_ time: Double, mode: FrameInterpolationMode = .auto, cap: Int = 30, panel: Int = 60,
          rate: Double = 30, mean: Double = 1000/30, p95: Double = 35, gpu: Double? = 4, pressure: Bool = false) -> Int {
 policy.update(mode: mode, cap: cap, panelFPS: panel, nativeFPS: rate, meanMS: mean, p95MS: p95, gpuMS: gpu, constrained: pressure, now: time)
}
assert(tick(1)==1 && tick(2)==1 && tick(3)==2 && policy.enabled)
assert(tick(4,pressure:true)==4 && !policy.enabled)
assert(tick(5)==1 && tick(6)==1 && tick(7)==1 && tick(8)==1 && tick(9)==2)
policy.reset();assert(tick(1,panel:30)==5 && !policy.enabled)
assert(tick(2,cap:40)==5);assert(tick(3,rate:20)==6);assert(tick(4,p95:50)==6)
assert(tick(5,gpu:nil)==9);assert(tick(6,gpu:.nan)==9);assert(tick(7,gpu:20)==9)
assert(tick(8,mode:.off)==0 && !policy.enabled)
assert(tick(9,mode:.auto,gpu:7)==9) // Auto enters with stricter headroom
assert(tick(10,mode:.double,gpu:7)==2 && policy.enabled) // manual enters immediately
assert(tick(11,mode:.double,rate:25,mean:40,p95:80,gpu:12)==2 && policy.enabled)
assert(tick(12,mode:.double,rate:20,mean:50,p95:100)==2 && policy.enabled)
assert(tick(13,mode:.double,rate:28,mean:35,p95:.nan)==2 && policy.enabled)
assert(tick(14,mode:.double,gpu:16)==9 && !policy.enabled)
assert(tick(15,mode:.double,pressure:true)==4 && !policy.enabled)
assert(tick(16,mode:.double,rate:22,mean:45,p95:90)==2 && policy.enabled)
assert(tick(17,mode:.double,rate:0)==6 && !policy.enabled)
assert(tick(18,mode:.double,rate:.nan)==6 && !policy.enabled)
assert(tick(19,mode:.double,panel:30)==5 && !policy.enabled)
assert(tick(20,mode:.double,gpu:nil)==9 && !policy.enabled)
assert(tick(.nan,mode:.double)==1 && !policy.enabled)
print("PASS: Auto stable admission/cooldown, manual uneven FPS and immediate admission, pressure/display limits and measured GPU headroom")
'''
with tempfile.TemporaryDirectory() as directory:
 work=Path(directory);cpp=work/'core.cpp';cpp.write_text(adapter+core+checks)
 subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-Wall','-Wextra','-I'+str(root/'app/Madeira'),str(cpp),'-o',str(work/'core')],check=True)
 subprocess.run([str(work/'core')],check=True)
 main=work/'main.swift';main.write_text(swift)
 subprocess.run([os.environ.get('SWIFTC','swiftc'),str(root/'app/Madeira/PerformancePolicy.swift'),str(main),'-o',str(work/'admission')],check=True)
 subprocess.run([str(work/'admission')],check=True)
