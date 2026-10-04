#include <metal_stdlib>
using namespace metal;

// Core begin: host tests compile these exact functions with texture adapters.
inline float of_cost(texture2d<float, access::read> a, texture2d<float, access::read> b,
                     int2 p, int2 displacement) {
    int2 limit = int2(a.get_width()-1, a.get_height()-1);
    float error = 0;
    for (int y=-4; y<=4; y+=4) for (int x=-4; x<=4; x+=4) {
        int2 q = clamp(p+int2(x,y), int2(0), limit);
        int2 r = clamp(p+int2(x,y)+displacement, int2(0), limit);
        float4 aa = a.read(uint2(q)), bb = b.read(uint2(r));
        error += (abs(aa.x-bb.x)+abs(aa.y-bb.y)+abs(aa.z-bb.z))/3;
    }
    return error/9;
}
inline float4 of_match(texture2d<float, access::read> a, texture2d<float, access::read> b, int2 p) {
    float best = 10, raw = 1;
    int2 displacement = int2(0);
    for (int y=-16; y<=16; y+=4) for (int x=-16; x<=16; x+=4) {
        float cost = of_cost(a,b,p,int2(x,y));
        float score = cost + float(abs(x)+abs(y))*0.00002;
        if (score < best) { best=score; raw=cost; displacement=int2(x,y); }
    }
    int2 coarse = displacement;
    for (int y=-2; y<=2; y++) for (int x=-2; x<=2; x++) {
        int2 d = coarse+int2(x,y);
        float cost = of_cost(a,b,p,d);
        float score = cost + float(abs(d.x)+abs(d.y))*0.00002;
        if (score < best) { best=score; raw=cost; displacement=d; }
    }
    return float4(float(displacement.x),float(displacement.y),raw,0);
}
inline bool of_confident(float4 forward, float4 backward) {
    return forward.z < 0.08 && backward.z < 0.08 &&
        length(float2(forward.x+backward.x,forward.y+backward.y)) <= 4;
}
inline float4 of_midpoint(texture2d<float, access::sample> previous, texture2d<float, access::sample> current,
                          int2 pixel, float4 forward, float4 backward) {
    if (!of_confident(forward,backward)) return current.read(uint2(pixel));
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 size = float2(previous.get_width(),previous.get_height());
    float2 p = float2(pixel)+float2(0.5);
    float2 fromPrevious = (p-float2(forward.x,forward.y)*0.5)/size;
    float2 fromCurrent = (p-float2(backward.x,backward.y)*0.5)/size;
    return (previous.sample(s,fromPrevious)+current.sample(s,fromCurrent))*0.5;
}
// Core end

kernel void madeira_flow(texture2d<float, access::read> previous [[texture(0)]],
                         texture2d<float, access::read> current [[texture(1)]],
                         device float4 *forward [[buffer(0)]], device float4 *backward [[buffer(1)]],
                         device atomic_uint *summary [[buffer(2)]], uint2 tile [[thread_position_in_grid]]) {
    uint columns = (previous.get_width()+15)/16, rows = (previous.get_height()+15)/16;
    if (tile.x>=columns || tile.y>=rows) return;
    int2 center = min(int2(tile*16+8),int2(previous.get_width()-1,previous.get_height()-1));
    float4 f = of_match(previous,current,center), b = of_match(current,previous,center);
    uint index = tile.y*columns+tile.x;
    forward[index]=f; backward[index]=b;
    atomic_fetch_add_explicit(summary+0,1u,memory_order_relaxed);
    atomic_fetch_add_explicit(summary+1,of_confident(f,b)?0u:1u,memory_order_relaxed);
    atomic_fetch_add_explicit(summary+2,uint((f.z+b.z)*5000),memory_order_relaxed);
}
kernel void madeira_midpoint(texture2d<float, access::sample> previous [[texture(0)]],
                             texture2d<float, access::sample> current [[texture(1)]],
                             texture2d<float, access::write> output [[texture(2)]],
                             device const float4 *forward [[buffer(0)]], device const float4 *backward [[buffer(1)]],
                             uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x>=output.get_width() || pixel.y>=output.get_height()) return;
    uint columns = (output.get_width()+15)/16;
    uint index = (pixel.y/16)*columns+pixel.x/16;
    output.write(of_midpoint(previous,current,int2(pixel),forward[index],backward[index]),pixel);
}
