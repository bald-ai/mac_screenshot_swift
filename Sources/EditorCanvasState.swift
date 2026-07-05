import AppKit
import Foundation

struct EditorCanvasState: Codable {
    struct Point: Codable, Equatable {
        var x: CGFloat
        var y: CGFloat

        init(_ point: NSPoint) {
            self.x = point.x
            self.y = point.y
        }

        var nsPoint: NSPoint {
            NSPoint(x: x, y: y)
        }
    }

    struct Rect: Codable, Equatable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat

        init(_ rect: NSRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.width
            self.height = rect.height
        }

        var nsRect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    struct Color: Codable, Equatable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat

        init(_ color: NSColor) {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            self.red = rgb.redComponent
            self.green = rgb.greenComponent
            self.blue = rgb.blueComponent
            self.alpha = rgb.alphaComponent
        }

        var nsColor: NSColor {
            NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    struct Text: Codable, Equatable {
        var text: String
        var origin: Point
        var color: Color
        var fontSize: CGFloat
    }

    enum Item: Codable, Equatable {
        case pen(points: [Point], color: Color, lineWidth: CGFloat)
        case arrow(start: Point, end: Point, color: Color, lineWidth: CGFloat)
        case rect(rect: Rect, color: Color, lineWidth: CGFloat)
        case ellipse(rect: Rect, color: Color, lineWidth: CGFloat)
        case text(Text)
        case image(pngData: Data, rect: Rect)
        case erase(rect: Rect)

        private enum CodingKeys: String, CodingKey {
            case type
            case points
            case start
            case end
            case color
            case lineWidth
            case rect
            case text
            case pngData
        }

        private enum Kind: String, Codable {
            case pen
            case arrow
            case rect
            case ellipse
            case text
            case image
            case erase
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(Kind.self, forKey: .type)
            switch type {
            case .pen:
                self = .pen(points: try container.decode([Point].self, forKey: .points),
                            color: try container.decode(Color.self, forKey: .color),
                            lineWidth: try container.decode(CGFloat.self, forKey: .lineWidth))
            case .arrow:
                self = .arrow(start: try container.decode(Point.self, forKey: .start),
                              end: try container.decode(Point.self, forKey: .end),
                              color: try container.decode(Color.self, forKey: .color),
                              lineWidth: try container.decode(CGFloat.self, forKey: .lineWidth))
            case .rect:
                self = .rect(rect: try container.decode(Rect.self, forKey: .rect),
                             color: try container.decode(Color.self, forKey: .color),
                             lineWidth: try container.decode(CGFloat.self, forKey: .lineWidth))
            case .ellipse:
                self = .ellipse(rect: try container.decode(Rect.self, forKey: .rect),
                                color: try container.decode(Color.self, forKey: .color),
                                lineWidth: try container.decode(CGFloat.self, forKey: .lineWidth))
            case .text:
                self = .text(try container.decode(Text.self, forKey: .text))
            case .image:
                self = .image(pngData: try container.decode(Data.self, forKey: .pngData),
                              rect: try container.decode(Rect.self, forKey: .rect))
            case .erase:
                self = .erase(rect: try container.decode(Rect.self, forKey: .rect))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pen(let points, let color, let lineWidth):
                try container.encode(Kind.pen, forKey: .type)
                try container.encode(points, forKey: .points)
                try container.encode(color, forKey: .color)
                try container.encode(lineWidth, forKey: .lineWidth)
            case .arrow(let start, let end, let color, let lineWidth):
                try container.encode(Kind.arrow, forKey: .type)
                try container.encode(start, forKey: .start)
                try container.encode(end, forKey: .end)
                try container.encode(color, forKey: .color)
                try container.encode(lineWidth, forKey: .lineWidth)
            case .rect(let rect, let color, let lineWidth):
                try container.encode(Kind.rect, forKey: .type)
                try container.encode(rect, forKey: .rect)
                try container.encode(color, forKey: .color)
                try container.encode(lineWidth, forKey: .lineWidth)
            case .ellipse(let rect, let color, let lineWidth):
                try container.encode(Kind.ellipse, forKey: .type)
                try container.encode(rect, forKey: .rect)
                try container.encode(color, forKey: .color)
                try container.encode(lineWidth, forKey: .lineWidth)
            case .text(let text):
                try container.encode(Kind.text, forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let pngData, let rect):
                try container.encode(Kind.image, forKey: .type)
                try container.encode(pngData, forKey: .pngData)
                try container.encode(rect, forKey: .rect)
            case .erase(let rect):
                try container.encode(Kind.erase, forKey: .type)
                try container.encode(rect, forKey: .rect)
            }
        }
    }

    var version: Int = 1
    var baseImagePNG: Data
    var items: [Item]
}
