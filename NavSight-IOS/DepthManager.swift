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
    
    // MARK: - Speech Categories
    
    // Separate speech into two categories for better responsiveness
    private enum SpeechCategory {
        case status     // Distance & location awareness (more permissive)
        case command    // Navigation & safety commands (strictly rate-limited)
    }
    
    // MARK: - Properties
    
    private let speechManager = SpeechManager()
    
    // Separate tracking for status vs command speech
    private var lastStatusSpeechTime: Date = .distantPast
    private var lastCommandSpeechTime: Date = .distantPast
    private var lastSpokenMessage: String = ""
    
    // State tracking
    private var lastSpokenState: DistanceState?
    private var lastSpokenDepth: Float = 0.0
    private var lastSpokenDirection: NavigationDirection?
    
    // Thresholds for status speech (distance awareness)
    private let statusDepthChangeThreshold: Float = 0.5 // meters - announce every ~0.5m change
    private let statusMinimumInterval: TimeInterval = 2.0 // seconds - more frequent updates
    
    // Thresholds for command speech (navigation & safety)
    private let commandMinimumInterval: TimeInterval = 4.0 // seconds - strictly rate-limited
    
    // General thresholds
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
    
    // MARK: - Refactored Audio Triggering Logic (Phase 5)
    
    /// Refactored speech logic separating STATUS vs COMMAND speech
    ///
    /// WHY THIS IMPROVES PHASE 5 USABILITY:
    /// - Phase 4 logic was designed for distance-only awareness with strict 4-second gates
    /// - Phase 5 adds directional navigation, requiring more frequent spatial updates
    /// - Old logic caused long silences while user is moving, reducing situational awareness
    /// - New logic provides continuous guidance without overwhelming the user
    ///
    /// STATUS SPEECH (Distance & Location Awareness):
    /// - Announces every ~0.5m depth change (user is moving)
    /// - Minimum 2.5s interval (more permissive)
    /// - Examples: "2.5 meters ahead", "Object on the left at 1.2 meters"
    /// - Keeps user informed of environment while walking
    ///
    /// COMMAND SPEECH (Navigation & Safety):
    /// - Strictly rate-limited (4s minimum)
    /// - Only triggers on direction changes or danger state changes
    /// - Examples: "Move left", "Warning, 30 centimeters, move right"
    /// - Prevents command spam while maintaining safety
    ///
    private func triggerSpeechIfNeeded(leftDepth: Float, centerDepth: Float, rightDepth: Float, direction: NavigationDirection) {
        let currentState = DistanceState.from(depth: centerDepth)
        let now = Date()
        
        // Determine speech category based on message content
        let centerBlocked = centerDepth < safetyThreshold
        let isCommandSpeech = centerBlocked || currentState == .veryClose
        let category: SpeechCategory = isCommandSpeech ? .command : .status
        
        // Get appropriate time gate based on category
        let timeSinceLastSpeech: TimeInterval
        let minimumInterval: TimeInterval
        
        switch category {
        case .status:
            timeSinceLastSpeech = now.timeIntervalSince(lastStatusSpeechTime)
            minimumInterval = statusMinimumInterval
        case .command:
            timeSinceLastSpeech = now.timeIntervalSince(lastCommandSpeechTime)
            minimumInterval = commandMinimumInterval
        }
        
        // Calculate depth change since last announcement
        let depthChange = abs(centerDepth - lastSpokenDepth)
        
        // TRIGGERING CONDITIONS
        
        // CONDITION 1: State changed (e.g. CLOSE → MEDIUM)
        let stateChanged = lastSpokenState != currentState
        
        // CONDITION 2: Significant depth change (user is moving)
        // More permissive for status speech to provide continuous updates
        let hasSignificantDepthChange = depthChange >= statusDepthChangeThreshold
        
        // CONDITION 3: Direction changed (navigation command needed)
        let directionChanged = lastSpokenDirection != direction
        
        // CONDITION 4: Time gate passed
        let timeGatePassed = timeSinceLastSpeech >= minimumInterval
        
        // CONDITION 5: Safety override - VERY_CLOSE always bypasses time gate
        let isSafetyOverride = currentState == .veryClose
        
        // DECISION LOGIC BY CATEGORY:
        
        let shouldTrigger: Bool
        
        if category == .command {
            // COMMAND SPEECH: Strict rate-limiting, only on state/direction changes
            shouldTrigger = (stateChanged || directionChanged) && (timeGatePassed || isSafetyOverride)
        } else {
            // STATUS SPEECH: More permissive, allows depth change updates
            shouldTrigger = (stateChanged || hasSignificantDepthChange || directionChanged) && (timeGatePassed || isSafetyOverride)
        }
        
        if shouldTrigger {
            // Build speech message with spatial context
            let message = buildSpeechMessage(leftDepth: leftDepth, centerDepth: centerDepth, rightDepth: rightDepth, direction: direction)
            
            // AVOID REPEATING IDENTICAL PHRASES BACK-TO-BACK
            // This prevents "2.5 meters ahead" → "2.5 meters ahead" repetition
            guard message != lastSpokenMessage else {
                print("⏭️  Skipping duplicate message: \"\(message)\"")
                return
            }
            
            // Trigger speech
            speechManager.speak(message)
            
            // Update tracking variables
            lastSpokenState = currentState
            lastSpokenDepth = centerDepth
            lastSpokenDirection = direction
            lastSpokenMessage = message
            
            // Update appropriate time tracker based on category
            switch category {
            case .status:
                lastStatusSpeechTime = now
            case .command:
                lastCommandSpeechTime = now
            }
            
            // Debug log showing category and trigger reason
            var reasons: [String] = []
            if stateChanged { reasons.append("state change") }
            if hasSignificantDepthChange { reasons.append("depth change") }
            if directionChanged { reasons.append("direction change") }
            let reasonText = reasons.joined(separator: ", ")
            let override = isSafetyOverride ? " [SAFETY OVERRIDE]" : ""
            let categoryText = category == .command ? "COMMAND" : "STATUS"
            print("🔊 [\(categoryText)] Speech triggered: \(reasonText)\(override) - State: \(currentState), Direction: \(direction.description)")
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


