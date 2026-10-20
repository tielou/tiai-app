import SwiftUI
#if os(iOS)
import UIKit
#endif

struct InlineImageView: View {
    let dataURL: String
    /// Hands the decoded bytes up so the row can open the picture full screen.
    var onTap: ((Data) -> Void)? = nil

    #if os(iOS)
    @State private var image: UIImage?
    @State private var bytes: Data?
    #endif

    var body: some View {
        #if os(iOS)
        Group {
            if let image {
                // A button, not `.onTapGesture`: inside a scrollable row the bare
                // gesture loses to the scroll view and silently does nothing,
                // which is a confusing way for "tap to enlarge" to fail.
                Button {
                    if let bytes { onTap?(bytes) }
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open picture full screen")
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.4))
                    .frame(width: 160, height: 120)
            }
        }
        .onAppear { load() }
        #else
        Color.clear.frame(height: 0)
        #endif
    }

    #if os(iOS)
    private func load() {
        guard image == nil, let comma = dataURL.firstIndex(of: ",") else { return }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        if let data = Data(base64Encoded: base64) {
            bytes = data
            image = UIImage(data: data)
        }
    }
    #endif
}

struct RemoteImageView: View {
    let id: String
    let load: (String) async -> Data?
    var onTap: ((Data) -> Void)? = nil

    #if os(iOS)
    @State private var image: UIImage?
    @State private var bytes: Data?
    #endif
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        ZStack {
            if loading {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                ProgressView()
            } else if failed {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                #if os(iOS)
                if let image {
                    Button {
                        if let bytes { onTap?(bytes) }
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open picture full screen")
                }
                #endif
            }
        }
        .frame(maxWidth: 220, maxHeight: 260, alignment: .trailing)
        .task(id: id) {
            #if os(iOS)
            guard image == nil else { return }
            guard let data = await load(id), let loaded = UIImage(data: data) else {
                failed = true
                loading = false
                return
            }
            bytes = data
            image = loaded
            loading = false
            #else
            loading = false
            #endif
        }
    }
}

/// A picture opened from a message.
struct ZoomImage: Identifiable, Equatable {
    let id: String
    let data: Data
}

/// The picture at the size it was taken at.
///
/// Tap anywhere to put it back. Pinch to enlarge, drag to pan what the pinch
/// moved off screen, double-tap to reset. The scale is clamped rather than free:
/// past about 5x a phone photo is mush and the gesture starts fighting itself,
/// and below 1x the image floats away from the edges of the screen for no
/// reason.
struct FullScreenImageView: View {
    let data: Data
    var onClose: () -> Void

    #if os(iOS)
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .offset(x: offset.width + gestureOffset.width,
                            y: offset.height + gestureOffset.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { gestureScale = $0 }
                            .onEnded { _ in
                                scale = min(max(scale * gestureScale, 1), 5)
                                gestureScale = 1
                                if scale == 1 { offset = .zero }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { gestureOffset = $0.translation }
                            .onEnded { _ in
                                guard scale > 1 else { gestureOffset = .zero; return }
                                offset.width += gestureOffset.width
                                offset.height += gestureOffset.height
                                gestureOffset = .zero
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.25)) {
                            scale = 1
                            offset = .zero
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85), .black.opacity(0.35))
                            .padding(20)
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onAppear { image = UIImage(data: data) }
        #else
        Color.black.ignoresSafeArea().onTapGesture { onClose() }
        #endif
    }
}

extension View {
    /// Full screen on iOS, a sheet on macOS.
    ///
    /// `fullScreenCover` does not exist on macOS, and the kit has to build there
    /// or `swift build` and the test suite stop working — the iOS-only code has
    /// to be stepped around rather than removed.
    @ViewBuilder
    func zoomCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { content($0) }
        #else
        sheet(item: item) { content($0) }
        #endif
    }
}

    /// A file the model made in its terminal sandbox, offered for download.
/// A file written to disk and ready to be previewed.
