import Cocoa

class WaveformView: NSView {
    private var waveform: [Float] = Array(repeating: 0, count: 40)
    private var smoothed: [Float] = Array(repeating: 0, count: 40)
    private var peakRms: Float = 0
    private var isRecording = false
    private var isTranscribing = false
    private var elapsed: Float = 0
    private var lastUpdate = CFAbsoluteTimeGetCurrent()

    // Theme colors
    var barColorIdle = NSColor(red: 0.51, green: 0.74, blue: 0.69, alpha: 1)
    var barColorRecording = NSColor.systemRed
    var barColorThinking = NSColor.systemOrange

    override var isFlipped: Bool { true }

    func update(waveform: [Float], peakRms: Float, isRecording: Bool, isTranscribing: Bool) {
        self.waveform = waveform
        self.peakRms = peakRms
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing

        let now = CFAbsoluteTimeGetCurrent()
        elapsed += Float(now - lastUpdate)
        lastUpdate = now

        // Smooth waveform — Apple uses very smooth transitions
        let lerp: Float = isRecording ? 0.25 : 0.1
        for i in 0..<min(smoothed.count, waveform.count) {
            smoothed[i] += (waveform[i] - smoothed[i]) * lerp
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let barCount = smoothed.count
        let padding: CGFloat = 12
        let totalWidth = bounds.width - padding * 2
        let gap: CGFloat = 3
        let barWidth: CGFloat = max((totalWidth / CGFloat(barCount)) - gap, 2)
        let centerY = bounds.height / 2
        let maxHeight = bounds.height * 0.75
        let minHeight: CGFloat = 3

        // Apple style: use system accent-aware colors, softer appearance
        let baseColor: NSColor
        if isRecording {
            baseColor = barColorRecording
        } else if isTranscribing {
            baseColor = barColorThinking
        } else {
            baseColor = barColorIdle
        }

        for i in 0..<barCount {
            let x = padding + CGFloat(i) * (barWidth + gap)
            let amplitude = CGFloat(smoothed[i])

            var height: CGFloat
            var alpha: CGFloat

            if isRecording {
                // Normalize by peak — always fills the space when speaking
                let norm = peakRms > 0.001 ? min(amplitude / CGFloat(peakRms), 1.0) : 0
                height = max(norm * maxHeight, minHeight)
                // Smooth alpha gradient — center bars slightly brighter (Apple Siri style)
                let centerFactor = 1.0 - abs(CGFloat(i) / CGFloat(barCount) - 0.5) * 0.4
                alpha = (0.3 + norm * 0.7) * centerFactor
            } else if isTranscribing {
                // Gentle breathing wave — Apple-style smooth sine
                let phase = elapsed * 2.0 + Float(i) * 0.12
                let wave = (sin(phase) + 1) / 2  // 0..1
                height = CGFloat(wave) * maxHeight * 0.25 + minHeight
                let centerFactor = 1.0 - abs(CGFloat(i) / CGFloat(barCount) - 0.5) * 0.6
                alpha = (0.2 + CGFloat(wave) * 0.4) * centerFactor
            } else {
                // Idle — subtle equal bars, very minimal
                height = minHeight
                alpha = 0.2
            }

            // Draw rounded bar from center — Apple's symmetric waveform style
            let halfH = height / 2
            let rect = CGRect(
                x: x,
                y: centerY - halfH,
                width: barWidth,
                height: height
            )

            ctx.setFillColor(baseColor.withAlphaComponent(alpha).cgColor)
            let cornerRadius = min(barWidth / 2, halfH)
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }
}
