//
//  ARViewContainer.swift
//  NavSight-IOS
//
//  ARKit + LiDAR setup for accessibility navigation
//

import SwiftUI
import ARKit
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    private let depthManager = DepthManager()
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // Attach depth manager as session delegate
        arView.session.delegate = depthManager
        
        // Configure AR session with LiDAR scene depth
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable LiDAR scene depth if supported
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        
        // Start the AR session
        arView.session.run(configuration)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // No updates needed for now
    }
}
