//
//  SimulationModel.swift
//  Slime
//
//  Created by Teddy Bersentes on 4/18/23.
//

import Foundation
import SwiftUI
import Metal
import MetalKit
import QuartzCore
import UIKit

func GetMetalDevice() -> MTLDevice? {
    MTLCreateSystemDefaultDevice()
}

protocol MetalRenderer {
    func render(_ texture: MTLTexture, buffer: MTLCommandBuffer)
}

struct EmptyRenderer: MetalRenderer {
    func render(_ texture: MTLTexture, buffer: MTLCommandBuffer) {}
}

struct Agent {
    let pos: (Float, Float)
    let dir: Float
    let species: (Int32, Int32, Int32, Int32)
    
    static var byteCount: Int { 8 * 4 }
}

struct SimulationConfig: Codable, Hashable {
    var sensorOffset: Float
    var sensorSize: Int32
    var sensorAngleSpacing: Float
    var turnSpeed: Float
    var evaporationSpeed: Float
    var moveSpeed: Float
    var trailWeight: Float
    var species: Int
    
    var floatSpecies: Float {
        get { Float(species) }
        set { species = Int(newValue) }
    }
    
    static var `default`: Self {
        .init(sensorOffset: 15, sensorSize: 1, sensorAngleSpacing: 0.2 * .pi, turnSpeed: 50, evaporationSpeed: 0.5, moveSpeed: 60, trailWeight: 1, species: 1)
    }
    
    static var byteCount: Int {
        return 7 * 4
    }
    
    func encoded() -> UnsafeRawPointer {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 7 * 4, alignment: MemoryLayout<Float>.alignment)
        
        ptr.assumingMemoryBound(to: Float.self)[0] = sensorOffset
        ptr.assumingMemoryBound(to: Int32.self)[1] = sensorSize
        ptr.assumingMemoryBound(to: Float.self)[2] = sensorAngleSpacing
        ptr.assumingMemoryBound(to: Float.self)[3] = turnSpeed
        ptr.assumingMemoryBound(to: Float.self)[4] = evaporationSpeed
        ptr.assumingMemoryBound(to: Float.self)[5] = moveSpeed
        ptr.assumingMemoryBound(to: Float.self)[6] = trailWeight
        
        return UnsafeRawPointer(ptr)
    }
}

func randomAgentInCircle(radius: Float, center: (Float, Float), species: (Int32, Int32, Int32)) -> Agent {
    let radSqrt = Float.random(in: 0 ... 1)
    let rad = radSqrt * radSqrt * radius
    let arg = Float.random(in: 0 ..< 2 * .pi)
    let pos = (cos(arg) * rad + center.0, sin(arg) * rad + center.1)
    let dir = arg + .pi
    return Agent(pos: pos, dir: dir, species: (species.0, species.1, species.2, 1))
}

class SimulationModel: MetalRenderer, ObservableObject {
    private let device: MTLDevice
    private let initState: MTLComputePipelineState
    private let agentsState: MTLComputePipelineState
    private let trailsState: MTLComputePipelineState
    private let speciesState: MTLComputePipelineState
    private let interactionsState: MTLComputePipelineState
    private var agents: MTLBuffer?
    private var previousTime: TimeInterval? = nil
    private var activeSpecies: Int = 1
    var sources: [(Float, Float, Bool)] = []
    var mouseEvents: [(Float, Float, Float, Float)] = []
    
    @Published var species: Int = 1
    @Published private var __agentCount: Int
    
    var agentCount: Int {
        didSet {
            let roundedValue = agentCount % 256 == 0 ? agentCount : ((agentCount / 256 + 1) * 256)
            __agentCount = min(max(roundedValue, 1<<10), 1<<24)
            agents = nil
        }
    }
    
    @Published var configuration: SimulationConfig = .default {
        didSet {
            species = configuration.species
        }
    }
    

    init(device: MTLDevice, agentCount: Int) {
        let compileOptions = MTLCompileOptions()
        compileOptions.fastMathEnabled = true
        guard
            let library = try? device.makeLibrary(source: SIM_SHADER, options: compileOptions),
            let initAgents = library.makeFunction(name: "initAgents"),
            let updateAgents = library.makeFunction(name: "updateAgents"),
            let updateTrails = library.makeFunction(name: "updateTrails"),
            let updateSpecies = library.makeFunction(name: "updateSpecies"),
            let performInteractions = library.makeFunction(name: "performInteractions"),
            let initState = try? device.makeComputePipelineState(function: initAgents),
            let agentsState = try? device.makeComputePipelineState(function: updateAgents),
            let trailsState = try? device.makeComputePipelineState(function: updateTrails),
            let speciesState = try? device.makeComputePipelineState(function: updateSpecies),
            let interactionsState = try? device.makeComputePipelineState(function: performInteractions)
        else {
            fatalError("Could not initalize sim model")
        }
        
        self.device = device
        self.initState = initState
        self.agentsState = agentsState
        self.trailsState = trailsState
        self.speciesState = speciesState
        self.interactionsState = interactionsState
        
        self.agentCount = agentCount
        let roundedAgentCount = agentCount % 256 == 0 ? agentCount : ((agentCount / 256 + 1) * 256)
        self.__agentCount = roundedAgentCount
    }
    
    private func initAgents(width: Int, height: Int, buffer: MTLCommandBuffer) {
        guard
            let agentBuffer = device.makeBuffer(length: Agent.byteCount * self.__agentCount, options: .storageModePrivate),
            let encoder = buffer.makeComputeCommandEncoder()
        else {
            return
        }
        
        let tgSize = MTLSize(width: 256, height: 1, depth: 1)
        let tgCount = MTLSize(width: (__agentCount + tgSize.width - 1) / tgSize.width, height: 1, depth: 1)
        
        encoder.setComputePipelineState(initState)
        encoder.setBuffer(agentBuffer, offset: 0, index: 0)
        encoder.setBytes([UInt32(width), UInt32(height)], length: 8, index: 1)
        encoder.setBytes([UInt32(__agentCount)], length: 4, index: 2)
        encoder.setBytes([UInt32(species)], length: 4, index: 3)
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
        
        self.agents = agentBuffer
    }
    
    private func updateAgents(texture: MTLTexture, buffer: MTLCommandBuffer, delta: Double) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        
        let tgSize = MTLSize(width: 256, height: 1, depth: 1)
        let tgCount = MTLSize(width: (__agentCount + tgSize.width - 1) / tgSize.width, height: 1, depth: 1)
        
        let configBytes = configuration.encoded()
        defer { configBytes.deallocate() }
        
        encoder.setComputePipelineState(self.agentsState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBuffer(agents, offset: 0, index: 0)
        encoder.setBytes([UInt32(texture.width), UInt32(texture.height)], length: 8, index: 1)
        encoder.setBytes([UInt32(__agentCount)], length: 4, index: 2)
        encoder.setBytes(configBytes, length: SimulationConfig.byteCount, index: 3)
        encoder.setBytes([Float(delta)], length: 4, index: 4)
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }
    
    private func updateTrails(texture: MTLTexture, buffer: MTLCommandBuffer, delta: Double) {
        guard let encoder = buffer.makeComputeCommandEncoder() else {
            return
        }
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (texture.width + tgSize.width - 1) / tgSize.width,
            height: (texture.height + tgSize.height - 1) / tgSize.height,
            depth: 1
        )
        
        let configBytes = configuration.encoded()
        defer {
            configBytes.deallocate()
        }
        
        encoder.setComputePipelineState(self.trailsState)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBytes([UInt32(texture.width), UInt32(texture.height)], length: 8, index: 0)
        encoder.setBytes(configBytes, length: SimulationConfig.byteCount, index: 1)
        encoder.setBytes([Float(delta)], length: 4, index: 2)
        
        let sourceData: [Float] = sources.suffix(256).flatMap {[$0 * 2, $1 * 2, $2 ? 1 : -1, 0]}
        
        encoder.setBytes(sourceData + (sources.isEmpty ? [Float(0), Float(0), Float(0), Float(0)] : []), length: max(sourceData.count, 4) * 4, index: 3)
        encoder.setBytes([UInt32(min(sources.count, 256))], length: 4, index: 4)
        encoder.setBytes([UInt32(species)], length: 4, index: 5)
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }
    
    private func updateSpeciesIfNecessary(buffer: MTLCommandBuffer) {
        guard activeSpecies != species, let encoder = buffer.makeComputeCommandEncoder() else {
            return
        }
        activeSpecies = species
        
        let tgSize = MTLSize(width: 256, height: 1, depth: 1)
        let tgCount = MTLSize(width: (__agentCount + tgSize.width - 1) / tgSize.width, height: 1, depth: 1)
        
        encoder.setComputePipelineState(speciesState)
        encoder.setBuffer(agents, offset: 0, index: 0)
        encoder.setBytes([UInt32(__agentCount)], length: 4, index: 1)
        encoder.setBytes([UInt32(species)], length: 4, index: 2)
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }
    
    func render(_ texture: MTLTexture, buffer: MTLCommandBuffer) {
        let time = CACurrentMediaTime()
        let delta: Double
        if let previousTime = self.previousTime {
            delta = min(time - previousTime, 1 / 20)
        } else {
            delta = 1.0 / 60.0
        }
        self.previousTime = time
        
        if agents == nil {
            initAgents(width: texture.width, height: texture.height, buffer: buffer)
        }
        
        updateSpeciesIfNecessary(buffer: buffer)
        updateAgents(texture: texture, buffer: buffer, delta: delta)
        updateTrails(texture: texture, buffer: buffer, delta: delta)
    }
}
