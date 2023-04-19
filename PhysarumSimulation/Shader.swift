//
//  shader.swift
//  Slime
//
//  Created by Teddy Bersentes on 4/18/23.
//

import Foundation

public let SIM_SHADER: String = """
#include <metal_stdlib>
using namespace metal;

#define PI 3.141592653589

typedef struct {
    float2 pos;
    float dir;
    float pad;
    int4 species;
} agent_t;

typedef struct {
    float sensor_offset;
    int sensor_size;
    float sensor_angle_spacing;
    float turn_speed;
    float evaporation_speed;
    float move_speed;
    float trail_weight;
} config_t;


uint hash(uint seed) {
    seed ^= 2447636419u;
    seed *= 2654435769u;
    seed ^= seed >> 16;
    seed *= 2654435769u;
    seed ^= seed >> 16;
    seed *= 2654435769u;
    return seed;
}

float sense(agent_t agent, float dir, int2 dim, texture2d<float, access::read> texture, const config_t config) {
    auto sensor_angle = agent.dir + dir;
    auto sensor_dir = float2(cos(sensor_angle), sin(sensor_angle));
    auto sensor_pos = agent.pos + sensor_dir * config.sensor_offset;
    
    float sum = 0;
    
    auto bound = config.sensor_size - 1;
    
    // sum = dot(texture.read(ushort2(sensor_pos)), float4(agent.species) * 2 - 1);
    
    for (int dy = -bound; dy <= bound; dy++) {
        for (int dx = -bound; dx <= bound; dx++) {
            int x = sensor_pos.x + dx;
            int y = sensor_pos.y + dy;
    
            if (x >= 0 && y >= 0 && x < dim.x && y < dim.y) {
                sum += dot(texture.read(ushort2(x, y)), float4(agent.species) * 2 - 1);
            }
        }
    }
    
    return sum;
}

float3 unitcircle_random(thread uint *seed) {
    auto argSeed = hash(*seed);
    auto absSeed = hash(argSeed);
    *seed = absSeed;
    
    auto arg = (float) argSeed / UINT_MAX * 2 * PI;
    auto absSqrt = (float) absSeed / UINT_MAX;
    auto absR = absSqrt * absSqrt;
    
    return float3(absR * cos(arg), absR * sin(arg), arg + PI);
}

kernel void initAgents(
    device agent_t *agents [[buffer(0)]],
    constant uint2 &dim [[buffer(1)]],
    constant uint &num_agents [[buffer(2)]],
    constant uint &num_species [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    auto mid = float2(dim) / 2;
    auto rad = float(min(dim.x, dim.y)) / 2;
    
    auto seed = gid;
    auto init = unitcircle_random(&seed);
    auto pos = float2(init.x, init.y) * rad + mid;
    
    agent_t agent = agents[gid];
    agent.pos = pos;
    agent.dir = init.z;
    
    if (num_species == 1) {
        agent.species = int4(0, 1, 1, 1);
    } else if (num_species == 2) {
        agent.species = int4(0, gid % 2, 1 - gid % 2, 1);
    } else if (num_species == 3) {
        agent.species = int4(gid % 3 == 2, gid % 3 == 1, gid % 3 == 0, 1);
    }
    
    agents[gid] = agent;
}

kernel void updateAgents(
    device agent_t *agents [[buffer(0)]],
    constant uint2 &dim [[buffer(1)]],
    constant uint &num_agents [[buffer(2)]],
    constant config_t &config [[buffer(3)]],
    constant float &time_delta [[buffer(4)]],
    texture2d<float, access::read> texture_read [[texture(0)]],
    texture2d<float, access::write> texture_write [[texture(1)]],
    uint gid [[thread_position_in_grid]]
) {
    auto idim = int2(dim);
    auto agent = agents[gid];
    auto rnd = hash(agent.pos.y * dim.x + agent.pos.x + hash(gid));
    auto dir_vec = float2(cos(agent.dir), sin(agent.dir));
    auto new_pos = agent.pos + config.move_speed * time_delta * dir_vec;
    
    if (new_pos.x < 0 || new_pos.y < 0 || new_pos.x >= dim.x || new_pos.y >= dim.y) {
        new_pos = clamp(new_pos, float2(0, 0), float2(dim) - 0.01);
        agent.dir = (float) rnd / UINT_MAX * 2 * PI;
    }
    agent.pos = new_pos;
    
    
    auto fwd_w = sense(agent, 0, idim, texture_read, config);
    auto left_w = sense(agent, config.sensor_angle_spacing, idim, texture_read, config);
    auto right_w = sense(agent, -config.sensor_angle_spacing, idim, texture_read, config);
    rnd = hash(rnd);
    
    auto rnd_steer_strength = (float) rnd / UINT_MAX;
    
    if (fwd_w >= left_w && fwd_w >= right_w) {
        // noop
    } else if (fwd_w < left_w && fwd_w < right_w) {
        agent.dir += (rnd_steer_strength - 0.5) * 2 * config.turn_speed * time_delta;
    } else if (right_w > left_w) {
        agent.dir -= rnd_steer_strength * config.turn_speed * time_delta;
    } else if (left_w > right_w) {
        agent.dir += rnd_steer_strength * config.turn_speed * time_delta;
    }
    
    agents[gid] = agent;
    texture_write.write(min(float4(agent.species) * config.trail_weight, 1), ushort2(new_pos));
}

kernel void updateTrails(
    texture2d<float, access::read> texture_read [[texture(0)]],
    texture2d<float, access::write> texture_write [[texture(1)]],
    constant uint2 &dim [[buffer(0)]],
    constant config_t &config [[buffer(1)]],
    constant float &time_delta [[buffer(2)]],
    device const float4 *sources [[buffer(3)]],
    constant uint &num_sources [[buffer(4)]],
    constant uint &num_species [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 sum = 0;
    const int2 idim = int2(dim);
    for (int dy = -1; dy <= 1 && (gid.y > 0 && gid.y < idim.y - 1); dy++) {
       for (int dx = -1; dx <= 1 && (gid.x > 0 && gid.x < idim.x - 1); dx++) {
            int x = gid.x + dx;
            int y = gid.y + dy;
            
            if (x >= 0 && y >= 0 && x < idim.x && y < idim.y) {
                sum += texture_read.read(ushort2(x, y));
            }
        }
    }
    
    // texture_write.write(sum / 9, ushort2(gid));
    
    // auto color = vec<float, 4>((float) gid.x / (float) dim.x, (float) gid.y / (float) dim.y, 1, 1);
    auto current = sum / 9;
    current *= max(0.01, 1 - config.evaporation_speed);
    current.w = 1;
    
    auto source_radius = (float) min(dim.x, dim.y) * 0.1f;
    for (uint i = 0; i < num_sources; i++) {
        auto source = sources[i];
        auto dist = distance(source.xy, float2(gid)) / source_radius;
        if (dist <= 1) {
            if (source.z < 0) {
                current = min(max(dist - 0.2, 0.0f), current);
            } else if (num_species == 1) {
                current.yz = max(1 - dist, current.yz);
            } else {
                current.y = max(1 - dist, current.y);
            }
        }
    }
    
    texture_write.write(current, ushort2(gid));
}

kernel void updateSpecies(
    device agent_t *agents [[buffer(0)]],
    constant uint &num_agents [[buffer(1)]],
    constant uint &num_species [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (num_species == 1) {
        agents[gid].species = int4(0, 1, 1, 1);
    } else if (num_species == 2) {
        agents[gid].species = int4(0, gid % 2, 1 - gid % 2, 1);
    } else if (num_species == 3) {
        agents[gid].species = int4(gid % 3 == 2, gid % 3 == 1, gid % 3 == 0, 1);
    }
}

kernel void performInteractions(
    device agent_t *agents [[buffer(0)]],
    constant uint &num_agents [[buffer(1)]],
    device const float4 *interaction_points [[buffer(2)]],
    constant uint &num_interactions [[buffer(3)]],
    constant uint &seed [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    auto rnd = hash(hash(gid) ^ seed);
    
    agent_t agent = agents[gid];
    
    for (uint i = 0; i < num_interactions; i++) {
        rnd = hash(rnd);
        float4 interaction = interaction_points[i];
        float2 pos = interaction.xy;
        float2 dirVec = interaction.zw;
        float dir = atan2(dirVec.y, dirVec.x);
        if ((float) rnd / UINT_MAX <= 0.0001) {
            agent.pos = pos + unitcircle_random(&rnd).xy * 20 - 10;
            agent.dir = dir;
        }
    }
    
    agents[gid] = agent;
}

"""


public let RENDER_SHADER = """
#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

typedef enum AAPLVertexInputIndex {
    AAPLVertexInputIndexVertices     = 0,
    AAPLVertexInputIndexViewportSize = 1,
} VertexInputIndex;

typedef struct {
    vector_float2 position;
    vector_float2 textureCoordinate;
} Vertex;

struct RasterizerData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
};

vertex RasterizerData vertexShader(
    uint vertexID [[ vertex_id ]],
    constant Vertex *vertexArray [[ buffer(AAPLVertexInputIndexVertices) ]],
    constant vector_uint2 *viewportSizePointer [[ buffer(AAPLVertexInputIndexViewportSize) ]]
) {
    RasterizerData out;
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    return out;
}

fragment float4 samplingShader(
    RasterizerData in [[stage_in]],
    texture2d<float> colorTexture [[ texture(0) ]]
) {
    constexpr sampler textureSampler (mag_filter::linear, min_filter::linear);
    const auto colorSample = colorTexture.sample (textureSampler, in.textureCoordinate);
    return colorSample;
}

kernel void clearTexture(texture2d<float, access::write> texture [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    texture.write(float4(0, 0, 0, 1), ushort2(gid));
}
"""
