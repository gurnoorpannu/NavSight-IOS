//
//  HapticManager.swift
//  NavSight-IOS
//
//  Continuous haptic feedback for visually impaired navigation
//  Provides non-intrusive background reassurance that the app is active
//

import UIKit
import CoreHaptics

class HapticManager {
    
    // MARK: - Haptic Patterns
    
    /// Haptic feedback patterns based on obstacle proximity
    enum HapticPattern {
        case clear          // Path clear - gentle heartbeat every 2-3s
        case approaching    // Obstacle 1.5-3.0m - moderate pulse every 1.5s
        case close          // Obstacle 0.5-1.5m - frequent pulse every 0.8s
        case veryClose      // Obstacle < 0.5m - continuous vibration
        case stopped        // No haptics (tracking lost, paused, background)
        
        var interval: TimeInterval {
            switch self {
            case .clear: return 2.5         // Gentle heartbeat
            case .approaching: return 1.5   // Moderate frequency
            case .close: return 0.8         // Frequent pulses
            case .veryClose: return 0.3     // Rapid continuous
            case .stopped: return .infinity // No haptics
            }
        }
        
        var intensity: Float {
            switch self {
            case .clear: return 0.3         // Subtle
            case .approaching: return 0.5   // Noticeable
            case .close: return 0.7         // Strong
            case .veryClose: return 1.0     // Maximum
            case .stopped: return 0.0       // None
            }
        }
        
        var sharpness: Float {
            switch self {
            case .clear: return 0.3         // Soft, gentle
            case .approaching: return 0.5   // Balanced
            case .close: return 0.7         // Sharp
            case .veryClose: return 1.0     // Very sharp
            case .stopped: return 0.0       // None
            }
        }
    }
    
    // MARK: - Properties
    
    private var impactGenerator: UIImpactFeedbackGenerator?
    private var currentImpactStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    private var hapticEngine: CHHapticEngine?
    private var currentPattern: HapticPattern = .stopped
    private var hapticTimer: Timer?
    private var lastHapticTime: Date = .distantPast
    private var isActive: Bool = false
    
    // MARK: - Initialization
    
    init() {
        setupHaptics()
    }
    
    /// Initialize haptic feedback generators
    private func setupHaptics() {
        // Try to use CoreHaptics for more precise control
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Fallback to UIImpactFeedbackGenerator
            impactGenerator = UIImpactFeedbackGenerator(style: .medium)
            impactGenerator?.prepare()
            print("📳 HapticManager: Using UIImpactFeedbackGenerator (CoreHaptics not available)")
            return
        }
        
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
            
            // Handle engine reset (e.g., after interruption)
            hapticEngine?.resetHandler = { [weak self] in
                print("📳 HapticManager: Engine reset, restarting...")
                do {
                    try self?.hapticEngine?.start()
                } catch {
                    print("📳 HapticManager: Failed to restart engine: \(error)")
                }
            }
            
            // Handle engine stopped
            hapticEngine?.stoppedHandler = { reason in
                print("📳 HapticManager: Engine stopped: \(reason)")
            }
            
            print("📳 HapticManager: CoreHaptics initialized successfully")
        } catch {
            print("📳 HapticManager: CoreHaptics failed, using fallback: \(error)")
            impactGenerator = UIImpactFeedbackGenerator(style: .medium)
            impactGenerator?.prepare()
        }
    }
    
    // MARK: - Public API
    
    /// Start haptic feedback system
    func start() {
        guard !isActive else { return }
        isActive = true
        print("📳 HapticManager: Started")
    }
    
    /// Stop all haptic feedback immediately
    /// Call when: tracking lost, AR paused, app backgrounded
    func stop() {
        guard isActive else { return }
        isActive = false
        currentPattern = .stopped
        stopHapticTimer()
        print("📳 HapticManager: Stopped")
    }
    
    /// Update haptic pattern based on obstacle distance
    /// - Parameter depth: Distance to nearest obstacle in meters
    func updateForDepth(_ depth: Float) {
        guard isActive else { return }
        
        // Determine appropriate haptic pattern based on depth
        let newPattern: HapticPattern
        
        if depth < 0.5 {
            newPattern = .veryClose      // < 0.5m - continuous vibration
        } else if depth < 1.5 {
            newPattern = .close          // 0.5-1.5m - frequent pulses
        } else if depth < 3.0 {
            newPattern = .approaching    // 1.5-3.0m - moderate pulses
        } else {
            newPattern = .clear          // > 3.0m - gentle heartbeat
        }
        
        // Only update if pattern changed
        if newPattern != currentPattern {
            currentPattern = newPattern
            restartHapticTimer()
            print("📳 HapticManager: Pattern changed to \(newPattern) (depth: \(String(format: "%.2f", depth))m)")
        }
    }
    
    // MARK: - Haptic Generation
    
    /// Restart the haptic timer with current pattern's interval
    private func restartHapticTimer() {
        stopHapticTimer()
        
        guard currentPattern != .stopped else { return }
        
        // Fire immediately for pattern changes
        triggerHaptic()
        
        // Schedule repeating timer
        hapticTimer = Timer.scheduledTimer(withTimeInterval: currentPattern.interval, repeats: true) { [weak self] _ in
            self?.triggerHaptic()
        }
    }
    
    /// Stop the haptic timer
    private func stopHapticTimer() {
        hapticTimer?.invalidate()
        hapticTimer = nil
    }
    
    /// Trigger a single haptic pulse with current pattern's characteristics
    private func triggerHaptic() {
        guard isActive, currentPattern != .stopped else { return }
        
        let now = Date()
        let timeSinceLastHaptic = now.timeIntervalSince(lastHapticTime)
        
        // Prevent haptics from firing too rapidly (safety check)
        guard timeSinceLastHaptic >= 0.2 else { return }
        
        lastHapticTime = now
        
        // Use CoreHaptics if available, otherwise fallback to UIImpactFeedbackGenerator
        if hapticEngine != nil {
            playHapticWithCoreHaptics()
        } else {
            playHapticWithImpactGenerator()
        }
    }
    
    /// Play haptic using CoreHaptics (more precise control)
    private func playHapticWithCoreHaptics() {
        guard let engine = hapticEngine else { return }
        
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: currentPattern.intensity)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: currentPattern.sharpness)
        
        // Create a short haptic event
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("📳 HapticManager: CoreHaptics playback error: \(error)")
        }
    }
    
    /// Play haptic using UIImpactFeedbackGenerator (fallback)
    private func playHapticWithImpactGenerator() {
        // Adjust impact style based on pattern intensity
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        
        switch currentPattern {
        case .clear:
            style = .light
        case .approaching:
            style = .medium
        case .close, .veryClose:
            style = .heavy
        case .stopped:
            return
        }
        
        // Recreate generator if style changed
        if currentImpactStyle != style {
            currentImpactStyle = style
            impactGenerator = UIImpactFeedbackGenerator(style: style)
            impactGenerator?.prepare()
        }
        
        impactGenerator?.impactOccurred()
    }
    
    // MARK: - Cleanup
    
    deinit {
        stop()
        hapticEngine?.stop()
    }
}
