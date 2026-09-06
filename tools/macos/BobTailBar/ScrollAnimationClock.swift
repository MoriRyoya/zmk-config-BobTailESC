import CoreVideo
import Foundation

/// Display-paced, coalesced main-thread animation. HID arrivals never restart
/// this clock. A timer is only the fallback when no display link is available.
final class ScrollAnimationClock {
    private var link: CVDisplayLink?
    private var source: DispatchSourceUserDataAdd?
    private var timer: Timer?
    private let tick: () -> Void

    init(tick: @escaping () -> Void) { self.tick = tick }
    deinit { stop() }

    func start() {
        guard link == nil && timer == nil else { return }
        let signal = DispatchSource.makeUserDataAddSource(queue: .main)
        signal.setEventHandler { [weak self] in self?.tick() }
        signal.resume(); source = signal
        var candidate: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&candidate) == kCVReturnSuccess, let candidate {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = CVDisplayLinkSetOutputCallback(candidate, { _, _, _, _, _, context in
                guard let context else { return kCVReturnError }
                Unmanaged<ScrollAnimationClock>.fromOpaque(context).takeUnretainedValue().source?.add(data: 1)
                return kCVReturnSuccess
            }, context)
            if result == kCVReturnSuccess && CVDisplayLinkStart(candidate) == kCVReturnSuccess {
                link = candidate
                return
            }
        }
        signal.cancel(); source = nil
        let fallback = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        fallback.tolerance = 0
        RunLoop.main.add(fallback, forMode: .common); timer = fallback
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
    }
}
