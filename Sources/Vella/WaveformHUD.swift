import AppKit
import SwiftUI

/// Procedural geometry/timing derived from the reference sequence, never raster assets.
struct WaveformMotion: Equatable {
    static let entranceSpeed = 3.5
    static let completionSpeed = 3.0
    static let completionDuration = 0.5 / completionSpeed
    static let warningWiggleDuration = 0.45
    var offsetX = 0.0
    var offsetY = 0.0
    var width = 1.0
    var height = 1.0
    var opacity = 1.0
    var brightness = 0.0
    var attachment = 0.0

    static func warning(age: Double, reduced: Bool) -> Self {
        if reduced { return Self() }
        if age >= warningWiggleDuration {
            return sample(entryAge: 2, finishAge: age - warningWiggleDuration, reduced: false)
        }
        let envelope = max(0, 1 - age / warningWiggleDuration)
        return Self(offsetX: sin(age * 65) * 4 * envelope,
                    offsetY: sin(age * 45) * 2 * envelope)
    }

    static func sample(entryAge: Double, finishAge: Double?, reduced: Bool) -> Self {
        if reduced { return Self(opacity: finishAge == nil ? 1 : 0) }
        if let age = finishAge {
            let t = max(0, age) * completionSpeed
            let contraction = min(1, max(0, (t - 0.09) / 0.38))
            let remaining = 1 - contraction
            return Self(width: max(0.008, pow(remaining, 2.3)),
                        height: (1 + sin(contraction * .pi) * 0.6) * pow(remaining, 0.6),
                        opacity: t >= 0.5 ? 0 : min(1, remaining * 5),
                        brightness: t < 0.09 ? sin(t / 0.09 * .pi) * 0.65 : 0.35 * remaining)
        }
        let t = max(0, entryAge) * entranceSpeed
        // Rise, detach, small overshoot, then damp into the resting position.
        let lift = t >= 1.2 ? 0 : t < 0.46 ? 47 * pow(1 - t / 0.46, 3) : -4 * exp(-(t - 0.46) * 8) * sin((t - 0.46) * 17)
        return Self(offsetY: lift, width: 0.68 + 0.32 * min(1, t / 0.48),
                    opacity: min(1, t / 0.10), attachment: max(0, 1 - t / 0.32))
    }
}

struct WaveformField: View {
    static let visibleDomain = 0.8 // Trim quiet tails without squeezing the active center.
    let level: Double
    let time: Double
    let motion: WaveformMotion
    var highContrast = false
    var warning = false

    var body: some View {
        Canvas { context, size in
            guard motion.opacity > 0 else { return }
            let energy = min(1, max(0, level.isFinite ? level : 0))
            let cx = size.width / 2 + motion.offsetX
            let cy = size.height / 2 + motion.offsetY
            let halfWidth = 91 * motion.width
            context.opacity = motion.opacity
            if motion.attachment > 0 {
                var stem = Path()
                stem.move(to: CGPoint(x: cx - 60 * motion.attachment, y: size.height))
                stem.addQuadCurve(to: CGPoint(x: cx - 8, y: cy + 2), control: CGPoint(x: cx - 17, y: cy + 18))
                stem.addQuadCurve(to: CGPoint(x: cx + 8, y: cy + 2), control: CGPoint(x: cx, y: cy - 9))
                stem.addQuadCurve(to: CGPoint(x: cx + 60 * motion.attachment, y: size.height), control: CGPoint(x: cx + 17, y: cy + 18))
                stem.closeSubpath()
                context.fill(stem, with: .linearGradient(Gradient(colors: [.white.opacity(0.25 * motion.attachment), .purple.opacity(0)]), startPoint: CGPoint(x: cx, y: cy), endPoint: CGPoint(x: cx, y: size.height)))
            }
            var paths: [Path] = []
            for layer in 0..<5 {
                let phase = time * 2.4 + Double(layer) * 1.35
                let shift = sin(phase) * 0.28 * energy * min(1, motion.width * 2)
                let breadth = 0.27 + Double(layer) * 0.055
                var path = Path()
                func point(_ i: Int, sign: Double) -> CGPoint {
                    let u = (Double(i) / 60 - 1) * Self.visibleDomain
                    let edge = min(1, max(0, (Self.visibleDomain - abs(u)) / 0.12))
                    let feather = edge * edge * (3 - 2 * edge)
                    let taper = max(0, 1 - u*u) * feather
                    let gaussian = exp(-pow((u - shift) / breadth, 2) * 1.5) * taper
                    let star = pow(max(0, 1 - abs(u - shift)), 3) * taper
                    let collapse = 1 - min(1, motion.width * 2)
                    let lobe = gaussian * (1 - collapse) + star * collapse
                    let ripple = 0.74 + 0.26 * cos(u * 8 - phase)
                    let thickness = (0.30 * taper + (5 + Double(layer) * 4) * energy * lobe * ripple) * motion.height
                    let attachmentBend = motion.attachment * pow(abs(u) / Self.visibleDomain, 0.7) * (size.height - cy)
                    let centre = cy + attachmentBend + sin(u * 5 + phase) * energy * 3 * lobe * motion.height
                    return CGPoint(x: cx + u * halfWidth, y: centre + sign * thickness)
                }
                path.move(to: point(0, sign: -1))
                for i in 1...120 { path.addLine(to: point(i, sign: -1)) }
                for i in stride(from: 120, through: 0, by: -1) { path.addLine(to: point(i, sign: 1)) }
                path.closeSubpath(); paths.append(path)
            }
            // A restrained halo belongs to the waveform itself, never a surrounding panel.
            context.drawLayer { halo in
                halo.addFilter(.blur(radius: 5 + motion.brightness * 6))
                halo.opacity = (energy * 0.04 + motion.brightness * 0.13)
                for path in paths { halo.fill(path, with: .color(warning ? Color(red: 1, green: 0.62, blue: 0.30) : Color(red: 0.77, green: 0.72, blue: 1))) }
            }
            for (index, path) in paths.enumerated() {
                let opacity = highContrast ? 0.65 : 0.28 + Double(index) * 0.055
                let edge = warning ? Color(red: 1, green: 0.46, blue: 0.12) : Color(red: 0.70, green: 0.64, blue: 0.98)
                let middle = warning ? Color(red: 1, green: 0.59, blue: 0.24) : Color(red: 0.76, green: 0.70, blue: 1)
                let gradient = Gradient(stops: [
                    .init(color: edge.opacity(0.08), location: 0),
                    .init(color: middle.opacity(opacity), location: 0.34),
                    .init(color: .white.opacity(min(1, opacity + 0.24 + motion.brightness)), location: 0.5),
                    .init(color: middle.opacity(opacity), location: 0.66),
                    .init(color: edge.opacity(0.08), location: 1)
                ])
                context.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: cx - halfWidth, y: cy), endPoint: CGPoint(x: cx + halfWidth, y: cy)))
            }
            if motion.width < 0.16 {
                let radius = max(0.6, motion.width * 12)
                context.fill(Path(ellipseIn: CGRect(x: cx-radius, y: cy-radius, width: radius*2, height: radius*2)), with: .color(.white))
            }
        }
        .shadow(color: .black.opacity(highContrast ? 0.6 : 0.25), radius: 1.2, y: 0.5)
        .accessibilityHidden(true)
    }
}

struct HUDView: View {
    static let panelSize = CGSize(width: 220, height: 124)
    static let successDwell = WaveformMotion.completionDuration + 0.025
    static let failureDwell = WaveformMotion.warningWiggleDuration + successDwell
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @VellaState private var entered = Date()
    @VellaState private var finished: Date?
    @VellaState private var previousPhase = Model.Phase.idle
    @VellaState private var lastVoiceLevel = 0.45
    var previewTime: Double? = nil
    var previewEntryAge: Double? = nil
    var previewFinishAge: Double? = nil

    static func animationPaused(phase: Model.Phase, visible: Bool, reduced: Bool) -> Bool {
        reduced || !visible || phase == .idle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: Self.animationPaused(phase: model.phase, visible: model.hudVisible, reduced: reduceMotion))) { timeline in
            let time = previewTime ?? timeline.date.timeIntervalSinceReferenceDate
            let entryAge = previewEntryAge ?? timeline.date.timeIntervalSince(entered)
            let finishAge = previewFinishAge ?? finished.map { timeline.date.timeIntervalSince($0) }
            let warning = model.phase == .failed
            let warningAge = max(0, previewFinishAge ?? timeline.date.timeIntervalSince(model.failureStartedAt))
            let motion = warning ? WaveformMotion.warning(age: warningAge, reduced: reduceMotion)
                : WaveformMotion.sample(entryAge: entryAge, finishAge: model.phase == .success ? finishAge : nil, reduced: reduceMotion)
            ZStack {
                if model.phase != .idle {
                    let level = model.phase == .recording ? model.audioLevel : model.phase == .success ? max(0.4, lastVoiceLevel) : 0.18 + (reduceMotion ? 0 : sin(time * 2) * 0.05)
                    WaveformField(level: warning ? 0.8 : level, time: reduceMotion ? 0 : warning ? warningAge * 7 : time,
                                  motion: motion, highContrast: reduceTransparency, warning: warning)
                }
                if model.phase == .transcribing && !model.processingProgress.isEmpty {
                    Text(model.processingProgress).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85)).shadow(color: .black.opacity(0.8), radius: 2)
                        .offset(y: 27)
                }
            }.frame(width: Self.panelSize.width, height: Self.panelSize.height)
        }
        .onChange(of: model.phase) { phase in
            if phase == .preparing || (phase == .recording && previousPhase != .preparing) || (phase == .transcribing && previousPhase == .failed) {
                entered = Date(); lastVoiceLevel = 0.45
            }
            finished = phase == .success ? Date() : nil
            previousPhase = phase
        }
        .onChange(of: model.audioLevel) { level in
            if model.phase == .recording && level > 0.02 { lastVoiceLevel = level }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase == .recording ? "Vella is recording. Control Command N to finish." : model.title)
    }
}
