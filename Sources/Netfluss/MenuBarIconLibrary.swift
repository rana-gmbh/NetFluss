// Copyright (C) 2026 Rana GmbH
//
// This file is part of Netfluss.
//
// Netfluss is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Netfluss is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Netfluss. If not, see <https://www.gnu.org/licenses/>.

import AppKit

struct MenuBarIconOption: Identifiable, Hashable {
    let id: String
    let label: String
}

enum MenuBarIconLibrary {
    static let options: [MenuBarIconOption] = [
        MenuBarIconOption(id: "network", label: "Network"),
        MenuBarIconOption(id: "arrow.up.arrow.down", label: "Arrows"),
        MenuBarIconOption(id: "wifi", label: "Wi-Fi"),
        MenuBarIconOption(id: "antenna.radiowaves.left.and.right", label: "Antenna"),
        MenuBarIconOption(id: "netfluss", label: "NetFluss")
    ]

    static func isSupported(_ id: String) -> Bool {
        options.contains { $0.id == id }
    }

    static func image(for id: String, pointSize: CGFloat) -> NSImage? {
        if id == "netfluss" {
            return netflussTemplateImage(pointSize: pointSize)
        }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(
            systemSymbolName: id,
            accessibilityDescription: "Menu bar icon"
        )?.withSymbolConfiguration(config)
    }

    private static func netflussTemplateImage(pointSize: CGFloat) -> NSImage? {
        let side = max(18, ceil(pointSize + 4))
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width, rect.height) / 20

            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * scale, y: y * scale)
            }

            let center = point(10, 10)
            let topLeft = point(6, 14.2)
            let topRight = point(15.2, 15.2)
            let bottomLeft = point(4.2, 4.2)
            let bottomCenter = point(10, 3.6)
            let bottomRight = point(14.1, 7.0)
            let nodes: [(point: NSPoint, radius: CGFloat)] = [
                (topLeft, 1.5 * scale),
                (topRight, 2.2 * scale),
                (bottomLeft, 2.1 * scale),
                (bottomCenter, 1.8 * scale),
                (bottomRight, 1.35 * scale)
            ]

            NSColor.black.setStroke()
            NSColor.black.setFill()

            let connectors = NSBezierPath()
            connectors.lineWidth = 1.75 * scale
            connectors.lineCapStyle = .round
            connectors.lineJoinStyle = .round
            for node in nodes {
                connectors.move(to: center)
                connectors.line(to: node.point)
            }
            connectors.stroke()

            let centerPath = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - (3 * scale),
                    y: center.y - (3 * scale),
                    width: 6 * scale,
                    height: 6 * scale
                )
            )
            centerPath.fill()

            for node in nodes {
                let path = NSBezierPath(
                    ovalIn: NSRect(
                        x: node.point.x - node.radius,
                        y: node.point.y - node.radius,
                        width: node.radius * 2,
                        height: node.radius * 2
                    )
                )
                path.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
