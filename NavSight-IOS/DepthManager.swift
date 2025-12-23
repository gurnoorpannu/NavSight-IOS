//
//  DepthManager.swift
//  NavSight-IOS
//
//  LiDAR depth value reader for accessibility navigation
//  Uses hybrid state-based + distance-change logic for stable audio feedback
//  Implements directional awareness (LEFT / CENTER / RIGHT) for navigation
//

import Foundation
import ARKit

class DepthManager: NSObject, ARSessionDelegate {
    
    // MARK: - Distance States
    
    // Define distance states for state-based triggering
    private enum DistanceState {
        case veryClose  // < 0.5m - urgent warning
        case close      // 0.5-1.5m - obstacle alert
        case medium     // 1.5-3.0m - informational
        case clear      // > 3.0m - clear path
        
        // Convert depth value to state
        static func from(depth: Float) -> DistanceState {
            if depth < 0.5 {
                return .veryClose
            } else if depth < 1.5 {
                return .close
            } else if depth < 3.0 {
                return .medium
            } else {
                return .clear
            }
        }
    }
    
    // MARK: - Direction Decision
    
    // Navigation direction based on spatial depth analysis
    enum NavigationDirection: Equatable {
        case forwardClear    // Center is clear, proceed forward
        case moveLeft        // Obstacle ahead, left is safer
        case moveRight       // Obstacle ahead, right is safer
        
        var description: String {
            switch self {
            case .forwardClear: return "Forward Clear"
            case .moveLeft: return "Move Left"
            case .moveRight: return "Move Right"
            }
        }
    }
    
    // MARK: - Properties
    
    private let speechManager = SpeechManager()
    
    // State tracking for distance-based announcements
    private var lastSpokenState: DistanceState?
    private var lastSpokenDepth: Float = 0.0
    private var lastSpokenTime: Date = .distantPast
    
    // Direction tracking
    private var lastSpokenDirection: NavigationDirection?
    
    // Thresholds
    private let significantDepthChange: Float = 0.5 // meters - announce if depth changes by this much
    private let minimumTimeBetweenAnnouncements: TimeInterval = 4.0 // seconds - prevents spam
    private let safetyThreshold: Float = 1.0 // meters - if center < this, suggest direction change
    
    // MARK: - ARSessionDelegate
    
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
        
        // Get base address and bytes per row
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        // Sample depth from three horizontal regions
        let leftDepth = sampleDepth(from: depthPointer, width: width, height: height, bytesPerRow: bytesPerRow, region: .left)
        let centerDepth = sampleDepth(from: depthPointer, width: width, height: height, bytesPerRow: bytesPerRow, region: .center)
        let rightDepth = sampleDepth(from: depthPointer, width: width, height: height, bytesPerRow: bytesPerRow, region: .right)
        
        // Determine navigation direction based on spatial depth analysis
        let direction = determineDirection(left: leftDepth, center: centerDepth, right: rightDepth)
        
        // Debug log showing all three depths and decision
        print("Left: \(String(format: "%.2f", leftDepth))m | Center: \(String(format: "%.2f", centerDepth))m | Right: \(String(format: "%.2f", rightDepth))m → Decision: \(direction.description)")
        
        // Trigger speech using hybrid strategy (distance + direction + spatial context)
        triggerSpeechIfNeeded(leftDepth: leftDepth, centerDepth: centerDepth, rightDepth: rightDepth, direction: direction)
    }
    
    // MARK: - Depth Sampling
    
    // Horizontal regions for depth sampling
    private enum SampleRegion {
        case left
        case center
        case right
    }
    
    /// Sample depth from a specific horizontal region of the depth map
    /// Uses a small averaged window for stability
    private func sampleDepth(from depthPointer: UnsafeMutablePointer<Float32>, width: Int, height: Int, bytesPerRow: Int, region: SampleRegion) -> Float {
        let centerY = height / 2
        let stride = bytesPerRow / MemoryLayout<Float32>.stride
        
        // Define horizontal position based on region
        let centerX: Int
        switch region {
        case .left:
            centerX = width / 4  // 25% from left
        case .center:
            centerX = width / 2  // 50% center
        case .right:
            centerX = (width * 3) / 4  // 75% from left
        }
        
        // Sample a 3x3 window for stability (reduces noise)
        var depthSum: Float = 0.0
        var sampleCount = 0
        
        for dy in -1...1 {
            for dx in -1...1 {
                let x = centerX + dx
                let y = centerY + dy
                
                // Bounds check
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                
                let index = y * stride + x
                let depth = depthPointer[index]
                
                // Filter out invalid depth values (0 or NaN)
                guard depth > 0 && depth.isFinite else { continue }
                
                depthSum += depth
                sampleCount += 1
            }
        }
        
        // Return average depth, or a large value if no valid samples
        return sampleCount > 0 ? depthSum / Float(sampleCount) : 10.0
    }
    
    // MARK: - Direction Logic
    
    /// Determine navigation direction based on left/center/right depth values
    /// Logic:
    /// - If center depth >= safety threshold (1.0m) → forwardClear
    /// - Otherwise, choose direction with maximum depth (safest path)
    private func determineDirection(left: Float, center: Float, right: Float) -> NavigationDirection {
        // If center is clear (>= safety threshold), proceed forward
        if center >= safetyThreshold {
            return .forwardClear
        }
        
        // Center has obstacle, choose safer direction
        // Compare left vs right depth to find the clearer path
        if left > right {
            return .moveLeft
        } else {
            return .moveRight
        }
    }
    
    // MARK: - Hybrid Audio Triggering Logic
    
    /// Determines if speech should be triggered using a hybrid strategy:
    /// 1. State-based: Announce when distance state changes (VERY_CLOSE → CLOSE, etc.)
    /// 2. Distance-based: Announce if depth changes by ≥ 0.5m within same state
    /// 3. Direction-based: Announce when navigation direction changes
    /// 4. Time-gated: Minimum 4 seconds between announcements (except VERY_CLOSE)
    /// 5. Safety override: VERY_CLOSE always bypasses time gate
    private func triggerSpeechIfNeeded(leftDepth: Float, centerDepth: Float, rightDepth: Float, direction: NavigationDirection) {
        let currentState = DistanceState.from(depth: centerDepth)
        let now = Date()
        let timeSinceLastAnnouncement = now.timeIntervalSince(lastSpokenTime)
        
        // Calculate absolute depth change since last announcement
        let depthChange = abs(centerDepth - lastSpokenDepth)
        
        // CONDITION 1: State changed (e.g. CLOSE → MEDIUM)
        let stateChanged = lastSpokenState != currentState
        
        // CONDITION 2: Significant depth change within same state
        let hasSignificantDepthChange = depthChange >= significantDepthChange
        
        // CONDITION 3: Direction changed (e.g. forwardClear → moveLeft)
        let directionChanged = lastSpokenDirection != direction
        
        // CONDITION 4: Time gate check
        let timeGatePassed = timeSinceLastAnnouncement >= minimumTimeBetweenAnnouncements
        
        // CONDITION 5: Safety override for very close obstacles
        let isSafetyOverride = currentState == .veryClose
        
        // HYBRID DECISION LOGIC:
        // Speak if:
        // - (State changed OR depth changed OR direction changed) AND (time gate passed OR safety override)
        let shouldTrigger = (stateChanged || hasSignificantDepthChange || directionChanged) && (timeGatePassed || isSafetyOverride)
        
        if shouldTrigger {
            // Build speech message with spatial context and direction guidance
            let message = buildSpeechMessage(leftDepth: leftDepth, centerDepth: centerDepth, rightDepth: rightDepth, direction: direction)
            
            // Trigger speech
            speechManager.speak(message)
            
            // Update tracking variables
            lastSpokenState = currentState
            lastSpokenDepth = centerDepth
            lastSpokenDirection = direction
            lastSpokenTime = now
            
            // Debug log to show why speech was triggered
            var reasons: [String] = []
            if stateChanged { reasons.append("state change") }
            if hasSignificantDepthChange { reasons.append("depth change") }
            if directionChanged { reasons.append("direction change") }
            let reasonText = reasons.joined(separator: ", ")
            let override = isSafetyOverride ? " [SAFETY OVERRIDE]" : ""
            print("🔊 Speech triggered: \(reasonText)\(override) - State: \(currentState), Direction: \(direction.description)")
        }
    }
    
    /// Build human-friendly speech message with spatial context
    /// Rules:
    /// - If center blocked (< 1.0m): Give turn command with distance
    /// - If center clear but side obstacle detected: Give spatial context without turn command
    /// - Otherwise: Simple distance announcement
    private func buildSpeechMessage(leftDepth: Float, centerDepth: Float, rightDepth: Float, direction: NavigationDirection) -> String {
        let centerBlocked = centerDepth < safetyThreshold
        
        // CASE 1: Center is blocked - give turn command
        if centerBlocked {
            let distanceText = formatDistanceForObstacle(centerDepth)
            
            switch direction {
            case .moveLeft:
                return "\(distanceText), move left"
            case .moveRight:
                return "\(distanceText), move right"
            case .forwardClear:
                // Shouldn't happen, but handle gracefully
                return distanceText
            }
        }
        
        // CASE 2: Center is clear - check for side obstacles and add spatial context
        // Find the nearest obstacle (minimum depth)
        let minDepth = min(leftDepth, centerDepth, rightDepth)
        
        // Only announce side obstacles if they're within awareness range (< 3.0m)
        if minDepth < 3.0 {
            // Determine which side has the nearest obstacle
            if leftDepth == minDepth && leftDepth < centerDepth {
                // Nearest obstacle is on the left
                let distanceText = formatDistance(leftDepth)
                return "Object on the left at \(distanceText)"
            } else if rightDepth == minDepth && rightDepth < centerDepth {
                // Nearest obstacle is on the right
                let distanceText = formatDistance(rightDepth)
                return "Object on the right at \(distanceText)"
            }
        }
        
        // CASE 3: No significant side obstacles - simple distance announcement
        return formatSimpleDistance(centerDepth)
    }
    
    /// Format distance for obstacle warnings (when center is blocked)
    private func formatDistanceForObstacle(_ distance: Float) -> String {
        if distance < 0.5 {
            let cm = Int(distance * 100)
            return "Warning, \(cm) centimeters"
        } else {
            return "Obstacle at \(formatDistance(distance))"
        }
    }
    
    /// Format simple distance announcement (when path is clear)
    private func formatSimpleDistance(_ distance: Float) -> String {
        if distance < 1.5 {
            return "\(formatDistance(distance)) ahead"
        } else if distance < 3.0 {
            return "\(formatDistance(distance)) ahead"
        } else {
            return "Clear"
        }
    }
    
    /// Format distance value as spoken text
    private func formatDistance(_ distance: Float) -> String {
        if distance < 1.0 {
            let cm = Int(distance * 100)
            return "\(cm) centimeters"
        } else {
            let meters = String(format: "%.1f", distance)
            return "\(meters) meters"
        }
    }
}


