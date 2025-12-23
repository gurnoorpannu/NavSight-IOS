//
//  DepthManager.swift
//  NavSight-IOS
//
//  LiDAR depth value reader for accessibility navigation
//

import Foundation
import ARKit

class DepthManager: NSObject, ARSessionDelegate {
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Access the scene depth data
        guard let sceneDepth = frame.sceneDepth else {
            return
        }
        
        // Get the depth map pixel buffer
        let depthMap = sceneDepth.depthMap
        
        // Lock the pixel buffer to read data
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        
        // Get buffer dimensions
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        // Calculate center pixel coordinates
        let centerX = width / 2
        let centerY = height / 2
        
        // Get base address and bytes per row
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        // Read depth value at center pixel (depth is stored as Float32)
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        let depthIndex = centerY * (bytesPerRow / MemoryLayout<Float32>.stride) + centerX
        let depthInMeters = depthPointer[depthIndex]
        
        // Print distance to console
        print("Center depth: \(String(format: "%.2f", depthInMeters)) meters")
    }
}
