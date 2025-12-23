//
//  SpeechManager.swift
//  NavSight-IOS
//
//  Audio feedback system for accessibility navigation
//

import Foundation
import AVFoundation

class SpeechManager {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenTime: Date = .distantPast
    private let cooldownInterval: TimeInterval = 2.5 // seconds between announcements
    
    // Speak distance information to the user
    // Example outputs:
    // - "Obstacle at one point two meters"
    // - "Warning, fifty centimeters"
    // - "Clear, three meters"
    func speakDistance(_ distance: Float) {
        // Check cooldown to prevent audio spam
        let now = Date()
        guard now.timeIntervalSince(lastSpokenTime) >= cooldownInterval else {
            return
        }
        
        let message = formatDistanceMessage(distance)
        speak(message)
        lastSpokenTime = now
    }
    
    // Convert numeric distance to human-friendly phrase
    private func formatDistanceMessage(_ distance: Float) -> String {
        if distance < 0.5 {
            // Very close - urgent warning
            let cm = Int(distance * 100)
            return "Warning, \(cm) centimeters"
        } else if distance < 1.5 {
            // Close - obstacle alert
            let distanceText = formatDistance(distance)
            return "Obstacle at \(distanceText)"
        } else if distance < 3.0 {
            // Medium distance - informational
            let distanceText = formatDistance(distance)
            return "\(distanceText) ahead"
        } else {
            // Far - clear path
            return "Clear"
        }
    }
    
    // Format distance value as spoken text
    // Examples: 1.2 -> "one point two meters", 0.75 -> "seventy five centimeters"
    private func formatDistance(_ distance: Float) -> String {
        if distance < 1.0 {
            let cm = Int(distance * 100)
            return "\(cm) centimeters"
        } else {
            let meters = String(format: "%.1f", distance)
            return "\(meters) meters"
        }
    }
    
    // Speak the given text using AVSpeechSynthesizer
    // Public method for custom messages (e.g. with directional guidance)
    func speak(_ text: String) {
        // Stop any ongoing speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5 // Slightly slower for clarity
        utterance.volume = 1.0
        
        synthesizer.speak(utterance)
        print("🔊 Speaking: \"\(text)\"")
    }
    
    // Stop any ongoing speech
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
