// Renders a mock desktop (wallpaper, menu bar and a colorful design app) for screenshots of Chroma.
// Usage: swift Scripts/make-demo-backdrop.swift <output.png> [width height]
// Point size defaults to 1920 × 1080; the image is rendered at 2x.
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make-demo-backdrop.swift <output.png> [width height]")
    exit(1)
}
let size = CGSize(
    width: args.count >= 4 ? Double(args[2])! : 1920,
    height: args.count >= 4 ? Double(args[3])! : 1080
)

func hex(_ value: UInt32) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

let ink = hex(0x1B1F3B)
let soft = hex(0x6B6F86)
let line = hex(0xE9E6F2)

struct Desktop: View {
    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            AppWindow()
                .frame(width: 1240, height: 760)
                .position(x: size.width / 2, y: size.height / 2 + 26)
        }
        .frame(width: size.width, height: size.height)
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [hex(0x2A1E5C), hex(0x6A3A8C), hex(0xE0795B)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(hex(0xFFB547).opacity(0.55)).frame(width: 900).blur(radius: 220).offset(x: 620, y: 380)
            Circle().fill(hex(0x2EC4B6).opacity(0.45)).frame(width: 800).blur(radius: 220).offset(x: -700, y: -300)
        }
    }

    private var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo").font(.system(size: 15, weight: .semibold))
            Text("Moodboard").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Board", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "drop.fill")
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Tue Nov 3  9:41 AM").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(.black.opacity(0.2))
    }
}

struct AppWindow: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        Photo(colors: [0xFF9A62, 0xE0566B, 0x5B2A86], sun: true).frame(height: 300)
                        HStack(spacing: 18) {
                            Photo(colors: [0x0B3D5C, 0x1F8A9E, 0x9EE6D8], waves: true)
                            Photo(colors: [0xF6E7C8, 0xF0B86E, 0xC2563A], sun: true)
                        }
                        .frame(height: 200)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        swatches
                        typeCard
                    }
                    .frame(width: 330)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hex(0xFBFAF7))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .compositingGroup() // otherwise the shadow is drawn under every subview
        .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(hex(0xFF5F57)).frame(width: 12)
                Circle().fill(hex(0xFEBC2E)).frame(width: 12)
                Circle().fill(hex(0x28C840)).frame(width: 12)
            }
            .padding(.bottom, 22)
            ForEach(Array(["Summer Campaign", "Brand Refresh", "Packaging", "Website", "Archive"].enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(.system(size: 14, weight: index == 0 ? .semibold : .regular))
                    .foregroundStyle(index == 0 ? ink : soft)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(index == 0 ? hex(0xECE8FB) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 230)
        .background(hex(0xF3F1EC))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Summer Campaign").font(.system(size: 30, weight: .bold)).foregroundStyle(ink)
                Text("Golden hour, coastline and warm paper. 24 references").font(.system(size: 14)).foregroundStyle(soft)
            }
            Spacer()
            Text("Share")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(hex(0x6A5AE0), in: Capsule())
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Palette").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            HStack(spacing: 10) {
                ForEach([0xFF7A59, 0xFFB547, 0x2EC4B6, 0x6A5AE0, 0x1B1F3B] as [UInt32], id: \.self) { c in
                    RoundedRectangle(cornerRadius: 10).fill(hex(c)).frame(height: 70)
                }
            }
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(line))
    }

    private var typeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aa").font(.system(size: 60, weight: .heavy, design: .serif)).foregroundStyle(hex(0xC2563A))
            Text("Sunset Serif").font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
            Text("Display headings, set tight with warm coral accents on paper.").font(.system(size: 13)).foregroundStyle(soft)
            HStack(spacing: 8) {
                Text("Coral").tagStyle(hex(0xFF7A59))
                Text("Lagoon").tagStyle(hex(0x2EC4B6))
                Text("Iris").tagStyle(hex(0x6A5AE0))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hex(0xFFF4E6), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension Text {
    func tagStyle(_ tint: Color) -> some View {
        self.font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 10).frame(height: 24)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A stylized landscape "photo": a gradient sky, a sun or waves, and hills.
struct Photo: View {
    let colors: [UInt32]
    var sun = false
    var waves = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: colors.map(hex), startPoint: .top, endPoint: .bottom)
                if sun {
                    Circle().fill(RadialGradient(colors: [hex(0xFFF1C1), hex(0xFFC46B).opacity(0.0)], center: .center, startRadius: 0, endRadius: h * 0.32))
                        .frame(width: h * 0.64).position(x: w * 0.68, y: h * 0.52)
                    Circle().fill(hex(0xFFE9B0)).frame(width: h * 0.2).position(x: w * 0.68, y: h * 0.52)
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.72))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.66), control1: CGPoint(x: w * 0.3, y: h * 0.55), control2: CGPoint(x: w * 0.65, y: h * 0.82))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(hex(waves ? 0x0E5F7A : 0x3A1F4D).opacity(0.85))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.86))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.8), control1: CGPoint(x: w * 0.4, y: h * 0.74), control2: CGPoint(x: w * 0.7, y: h * 0.92))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(hex(waves ? 0x083247 : 0x22122E))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

let output = URL(fileURLWithPath: args[1])
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Desktop().environment(\.colorScheme, .light))
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
    else {
        print("Rendering failed")
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("Wrote \(output.path) (\(image.width) × \(image.height))")
}
