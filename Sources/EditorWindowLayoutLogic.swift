import AppKit

struct EditorWindowLayoutInput {
    let imagePointSize: NSSize
    let maxContentSize: NSSize
    let minContentSize: NSSize
    let chromeSize: NSSize
    let wasResized: Bool
    let autoZoomFillRatio: CGFloat
    let maxAutoUserZoom: CGFloat
}

struct EditorWindowLayoutResult {
    let totalPadding: CGFloat
    let fitScale: CGFloat
    let contentSize: NSSize
    let defaultUserZoomFactor: CGFloat
}

enum EditorWindowLayoutLogic {
    static let fallbackMaxContentSize = NSSize(width: 1400.0, height: 900.0)
    static let visibleFrameUsageRatio: CGFloat = 0.90
    static let maxPadding: CGFloat = 40.0

    static func maximumContentSize(visibleFrame: NSRect?,
                                   minContentSize: NSSize,
                                   fallback: NSSize = fallbackMaxContentSize) -> NSSize {
        guard let visibleFrame else {
            return NSSize(width: max(minContentSize.width, fallback.width),
                          height: max(minContentSize.height, fallback.height))
        }

        let width = floor(visibleFrame.width * visibleFrameUsageRatio)
        let height = floor(visibleFrame.height * visibleFrameUsageRatio)
        return NSSize(width: max(minContentSize.width, width),
                      height: max(minContentSize.height, height))
    }

    static func makeLayout(_ input: EditorWindowLayoutInput) -> EditorWindowLayoutResult {
        let totalPadding = calculatePadding(imagePointSize: input.imagePointSize,
                                            maxContentSize: input.maxContentSize,
                                            chromeSize: input.chromeSize,
                                            wasResized: input.wasResized)

        let availableWidth = max(input.maxContentSize.width - input.chromeSize.width - totalPadding, 1.0)
        let availableHeight = max(input.maxContentSize.height - input.chromeSize.height - totalPadding, 1.0)

        var fitScale: CGFloat
        if input.imagePointSize.width <= availableWidth && input.imagePointSize.height <= availableHeight {
            fitScale = 1.0
        } else {
            fitScale = min(availableWidth / input.imagePointSize.width,
                           availableHeight / input.imagePointSize.height)
        }
        if !fitScale.isFinite || fitScale <= 0 {
            fitScale = 1.0
        }

        let contentWidth = min(max(input.imagePointSize.width * fitScale + totalPadding + input.chromeSize.width,
                                   input.minContentSize.width),
                               input.maxContentSize.width)
        let contentHeight = min(max(input.imagePointSize.height * fitScale + totalPadding + input.chromeSize.height,
                                    input.minContentSize.height),
                                input.maxContentSize.height)
        let contentSize = NSSize(width: contentWidth, height: contentHeight)

        var defaultUserZoomFactor: CGFloat = 1.0
        let unclampedWidth = input.imagePointSize.width * fitScale + totalPadding + input.chromeSize.width
        let unclampedHeight = input.imagePointSize.height * fitScale + totalPadding + input.chromeSize.height
        let hasExtraSlack = (contentWidth > unclampedWidth + 1.0) || (contentHeight > unclampedHeight + 1.0)

        if hasExtraSlack {
            let canvasWidth = contentWidth - input.chromeSize.width
            let canvasHeight = contentHeight - input.chromeSize.height
            let imageWidthAtFit = input.imagePointSize.width * fitScale
            let imageHeightAtFit = input.imagePointSize.height * fitScale

            if canvasWidth > 0, canvasHeight > 0, imageWidthAtFit > 0, imageHeightAtFit > 0 {
                let candidate = min((canvasWidth * input.autoZoomFillRatio) / imageWidthAtFit,
                                    (canvasHeight * input.autoZoomFillRatio) / imageHeightAtFit)
                if candidate.isFinite {
                    defaultUserZoomFactor = max(1.0, min(input.maxAutoUserZoom, candidate))
                }
            }
        }

        return EditorWindowLayoutResult(totalPadding: totalPadding,
                                        fitScale: fitScale,
                                        contentSize: contentSize,
                                        defaultUserZoomFactor: defaultUserZoomFactor)
    }

    private static func calculatePadding(imagePointSize: NSSize,
                                         maxContentSize: NSSize,
                                         chromeSize: NSSize,
                                         wasResized: Bool) -> CGFloat {
        if wasResized {
            return 0.0
        }

        let widthLimit = max(maxContentSize.width - maxPadding, 1.0)
        let heightLimit = max(maxContentSize.height - chromeSize.height - maxPadding, 1.0)
        let fillRatioWidth = imagePointSize.width / widthLimit
        let fillRatioHeight = imagePointSize.height / heightLimit
        let fillRatio = min(max(fillRatioWidth, fillRatioHeight), 1.0)
        return maxPadding * (1.0 - fillRatio)
    }
}
