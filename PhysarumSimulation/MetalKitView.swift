//
//  MetalKitView.swift
//  Slime
//
//  Created by Teddy Bersentes on 4/18/23.
//

import SwiftUI
import UIKit
import Foundation
import Metal
import MetalKit
import QuartzCore

class MetalViewController: UIViewController, MTKViewDelegate {
    let device: MTLDevice
    private(set) var metalView: MTKView!
    fileprivate(set) var renderer: MetalRenderer
    private var commandQueue: MTLCommandQueue
    private var texture: MTLTexture?
    private var fragmentShader: MTLFunction?
    private var vertexShader: MTLFunction?
    private var renderPipeline: MTLRenderPipelineState?
    private var clearState: MTLComputePipelineState?
    private var samplerState: MTLSamplerState?
    
    init(device: MTLDevice, renderer: MetalRenderer) {
        self.device = device
        self.renderer = renderer
        self.commandQueue = device.makeCommandQueue()!
        
        super.init()
    }
    
    required init?(coder: NSCoder) {
        guard let device = GetMetalDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.renderer = EmptyRenderer()
        self.commandQueue = queue
        super.init(coder: coder)
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        let device = GetMetalDevice()!
        let queue = device.makeCommandQueue()!
        self.device = device
        self.renderer = EmptyRenderer()
        self.commandQueue = queue
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    
    override func loadView() {
        let view = MTKView(frame: .zero, device: self.device)
        self.view = view
        self.metalView = view
        view.delegate = self
        
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        
        self.mtkView(view, drawableSizeWillChange: view.drawableSize)
        
        let compileOptions = MTLCompileOptions()
        compileOptions.fastMathEnabled = true
        
        guard let library = try? device.makeLibrary(source: RENDER_SHADER, options: compileOptions) else {
            print("Failed to create library")
            return 
        }
        fragmentShader = library.makeFunction(name: "samplingShader")
        vertexShader = library.makeFunction(name: "vertexShader")
        
        if let clearFunction = library.makeFunction(name: "clearTexture"),
           let state = try? device.makeComputePipelineState(function: clearFunction) {
            self.clearState = state
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "render pipeline"
        pipelineDescriptor.vertexFunction = vertexShader
        pipelineDescriptor.fragmentFunction = fragmentShader
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        self.renderPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            self.texture = nil
            return
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = Int(size.width)
        descriptor.height = Int(size.height)
        descriptor.textureType = .type2D
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard
            let texture = self.device.makeTexture(descriptor: descriptor),
            let buffer = commandQueue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder(),
            let state = clearState
        else {
            self.texture = nil
            return
        }
        
        encoder.setComputePipelineState(state)
        encoder.setTexture(texture, index: 0)
        
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (texture.width + tgSize.width - 1) / tgSize.width,
            height: (texture.height + tgSize.height - 1) / tgSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        
        self.texture = texture
    }
    
    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let buffer = commandQueue.makeCommandBuffer(),
            let drawable = view.currentDrawable,
            let texture = self.texture
        else {
            print("Failed to create initial draw variables")
            return
        }
        
        self.renderer.render(texture, buffer: buffer)
        
        guard let renderCommandEncoder = buffer.makeRenderCommandEncoder(descriptor: descriptor), let renderPipeline = self.renderPipeline else {
            print("Failed to make render command encoder")
            return
        }
        
        let viewportSize: [UInt32] = [UInt32(view.drawableSize.width), UInt32(view.drawableSize.height)]
        renderCommandEncoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(view.drawableSize.width), height: Double(view.drawableSize.height), znear: -1, zfar: 1))
        renderCommandEncoder.setRenderPipelineState(renderPipeline)
        
        let w = Float(viewportSize[0]) / 2
        let h = Float(viewportSize[1]) / 2
        
        let vertices: [Float] = [
             w, -h, 1, 1,
            -w, -h, 0, 1,
            -w,  h, 0, 0,
             w, -h, 1, 1,
            -w,  h, 0, 0,
             w,  h, 1, 0
        ]
        renderCommandEncoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<Float>.stride, index: 0)
        renderCommandEncoder.setVertexBytes(viewportSize, length: viewportSize.count * MemoryLayout<UInt32>.stride, index: 1)
        renderCommandEncoder.setFragmentTexture(texture, index: 0)
        renderCommandEncoder.setFragmentSamplerState(samplerState, index: 0)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderCommandEncoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}


struct MetalViewRepresentable: UIViewControllerRepresentable {
    let device: MTLDevice
    let renderer: MetalRenderer

    init(device: MTLDevice, renderer: MetalRenderer) {
        self.device = device
        self.renderer = renderer
    }

    func makeUIViewController(context: Context) -> MetalViewController {
        let vc = MetalViewController(device: device, renderer: renderer)
        vc.renderer = self.renderer
        return vc
    }
    
    func updateUIViewController(_ vc: MetalViewController, context: Context) {
        // You can update the `viewController` here if needed when SwiftUI updates the view
        vc.renderer = self.renderer
    }
}
