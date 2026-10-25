enum WaveShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Parameters {
        uint2 grid; float2 size; float2 visibleSize; uint2 renderGrid;
        float dt; float damping; uint count; float dark; float dotSize; float dotSpacing;
    };
    struct Impulse { float2 center; float radius; float strength; };
    uint indexAt(int x, int y, uint2 grid) {
        // Mirrored ghost cells impose zero normal flow at the pool walls.
        return uint(clamp(y, 0, int(grid.y)-1)) * grid.x + uint(clamp(x, 0, int(grid.x)-1));
    }
    kernel void waveStep(device const float2 *source [[buffer(0)]], device float2 *target [[buffer(1)]],
                         constant Parameters &p [[buffer(2)]], constant Impulse *impulses [[buffer(3)]],
                         uint i [[thread_position_in_grid]]) {
        if (i >= p.grid.x*p.grid.y) return;
        int x = int(i % p.grid.x), y = int(i / p.grid.x);
        float2 cell = p.size / float2(p.grid);
        float2 position = (float2(x,y)+0.5f)*cell;
        float h = source[i].x, v = source[i].y;
        for (uint j=0; j<p.count; j++) {
            float q = (distance(position, impulses[j].center+(p.size-p.visibleSize)*0.5f)-impulses[j].radius)/2.2f;
            v += impulses[j].strength*exp(-0.5f*q*q);
        }
        float lap = (source[indexAt(x-1,y,p.grid)].x + source[indexAt(x+1,y,p.grid)].x-2*h)/(cell.x*cell.x)
                  + (source[indexAt(x,y-1,p.grid)].x + source[indexAt(x,y+1,p.grid)].x-2*h)/(cell.y*cell.y);
        v = (v + 144.0f*lap*p.dt)*exp(-p.damping*p.dt);
        target[i] = float2(h+v*p.dt, v);
    }
    kernel void poolTotals(device const float2 *state [[buffer(0)]], constant Parameters &p [[buffer(1)]],
                           device float2 *mean [[buffer(2)]], device atomic_uint *energy [[buffer(3)]],
                           uint lane [[thread_index_in_threadgroup]]) {
        threadgroup float2 sums[256];
        uint count = p.grid.x*p.grid.y;
        float2 sum = float2(0);
        for (uint j=lane; j<count; j+=256) sum += state[j];
        sums[lane] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride=128; stride>0; stride/=2) {
            if (lane<stride) sums[lane] += sums[lane+stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (lane==0) {
            mean[0] = sums[0]/float(count);
            atomic_store_explicit(energy, 0u, memory_order_relaxed);
        }
    }
    kernel void levelPool(device float2 *state [[buffer(0)]], constant Parameters &p [[buffer(1)]],
                          device const float2 *mean [[buffer(2)]], device atomic_uint *energy [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
        if (i >= p.grid.x*p.grid.y) return;
        // Conserve volume and reduce energy in parallel over the larger hidden pool.
        state[i] -= mean[0];
        float peak = max(abs(state[i].x), abs(state[i].y)*0.15f);
        atomic_fetch_max_explicit(energy, as_type<uint>(peak), memory_order_relaxed);
    }
    float heightAt(float2 position, device const float2 *state, constant Parameters &p) {
        float2 coordinate = position/(p.size/float2(p.grid))-0.5f;
        int2 cell = int2(floor(coordinate));
        float2 f = fract(coordinate);
        float lower = mix(state[indexAt(cell.x,cell.y,p.grid)].x, state[indexAt(cell.x+1,cell.y,p.grid)].x,f.x);
        float upper = mix(state[indexAt(cell.x,cell.y+1,p.grid)].x, state[indexAt(cell.x+1,cell.y+1,p.grid)].x,f.x);
        return mix(lower,upper,f.y);
    }
    struct Point { float4 position [[position]]; float size [[point_size]]; float4 color; };
    float3 rainbow(float hue) {
        float3 rgb = clamp(abs(fract(hue+float3(0,2.0f/3,1.0f/3))*6-3)-1, 0.0f, 1.0f);
        return mix(float3(1), rgb, 0.68f);
    }
    vertex Point lattice(uint i [[vertex_id]], device const float2 *state [[buffer(0)]],
                         constant Parameters &p [[buffer(1)]], constant float &scale [[buffer(2)]]) {
        uint x = i%p.renderGrid.x, y = i/p.renderGrid.x;
        float2 visible = (float2(x,y)+0.5f)*p.dotSpacing+(p.visibleSize-float2(p.renderGrid)*p.dotSpacing)*0.5f;
        float2 uv = visible/p.visibleSize;
        float2 cell = p.size/float2(p.grid);
        float2 position = (p.size-p.visibleSize)*0.5f+visible;
        float h = heightAt(position,state,p);
        float2 slope = float2(heightAt(position+float2(cell.x,0),state,p)-heightAt(position-float2(cell.x,0),state,p),
                             heightAt(position+float2(0,cell.y),state,p)-heightAt(position-float2(0,cell.y),state,p))/(2*cell);
        float refraction = dot(slope, float2(-0.85f,0.3f));
        float brightness = (0.18f + min(length(slope)*2.2f,0.32f) + min(abs(h)*0.08f,0.08f))
                         * mix(0.85f,1.0f,p.dark);
        Point out;
        out.position = float4(uv*2-1,0,1);
        out.size = (p.dotSize+min(abs(h)*0.6f,0.65f))*scale;
        out.color = float4(rainbow(fract(0.55f+refraction*3.5f)),brightness);
        return out;
    }
    fragment float4 droplet(Point in [[stage_in]], float2 uv [[point_coord]]) {
        return float4(in.color.rgb, in.color.a*(1-smoothstep(0.32f,0.5f,length(uv-0.5f))));
    }
    """
}
