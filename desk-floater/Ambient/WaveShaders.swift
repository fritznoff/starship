enum WaveShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Parameters { uint2 grid; float2 size; float dt; float damping; uint count; float dark; };
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
            float q = (distance(position, impulses[j].center)-impulses[j].radius)/2.2f;
            v += impulses[j].strength*exp(-0.5f*q*q);
        }
        float lap = (source[indexAt(x-1,y,p.grid)].x + source[indexAt(x+1,y,p.grid)].x-2*h)/(cell.x*cell.x)
                  + (source[indexAt(x,y-1,p.grid)].x + source[indexAt(x,y+1,p.grid)].x-2*h)/(cell.y*cell.y);
        v = (v + 144.0f*lap*p.dt)*exp(-p.damping*p.dt);
        target[i] = float2(h+v*p.dt, v);
    }
    kernel void levelPool(device float2 *state [[buffer(0)]], constant Parameters &p [[buffer(1)]],
                          device float *energy [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        if (i != 0) return;
        uint count = p.grid.x*p.grid.y;
        float2 mean = float2(0);
        for (uint j=0; j<count; j++) mean += state[j];
        mean /= float(count);
        float peak = 0;
        for (uint j=0; j<count; j++) {
            // Conserve pool volume so clipped rings cannot leave a permanent DC level.
            state[j] -= mean;
            peak = max(peak, max(abs(state[j].x), abs(state[j].y)*0.15f));
        }
        energy[0] = peak;
    }
    struct Point { float4 position [[position]]; float size [[point_size]]; float4 color; };
    float3 rainbow(float hue) {
        float3 rgb = clamp(abs(fract(hue+float3(0,2.0f/3,1.0f/3))*6-3)-1, 0.0f, 1.0f);
        return mix(float3(1), rgb, 0.68f);
    }
    vertex Point lattice(uint i [[vertex_id]], device const float2 *state [[buffer(0)]],
                         constant Parameters &p [[buffer(1)]], constant float &scale [[buffer(2)]]) {
        int x = int(i%p.grid.x), y = int(i/p.grid.x);
        float2 cell = p.size/float2(p.grid);
        float2 uv = (float2(x,y)+0.5f)/float2(p.grid);
        float2 slope = float2(state[indexAt(x+1,y,p.grid)].x-state[indexAt(x-1,y,p.grid)].x,
                             state[indexAt(x,y+1,p.grid)].x-state[indexAt(x,y-1,p.grid)].x)/(2*cell);
        float refraction = dot(slope, float2(-0.85f,0.3f));
        float brightness = (0.18f + min(length(slope)*2.2f,0.32f) + min(abs(state[i].x)*0.08f,0.08f))
                         * mix(0.85f,1.0f,p.dark);
        Point out;
        out.position = float4(uv*2-1,0,1);
        out.size = (1.05f+min(abs(state[i].x)*0.6f,0.65f))*scale;
        out.color = float4(rainbow(fract(0.55f+refraction*3.5f)),brightness);
        return out;
    }
    fragment float4 droplet(Point in [[stage_in]], float2 uv [[point_coord]]) {
        return float4(in.color.rgb, in.color.a*(1-smoothstep(0.32f,0.5f,length(uv-0.5f))));
    }
    """
}
