import AVKit
import SwiftUI

/// AirPlay / Bluetooth output picker.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(named: "AccentColor") ?? .label
        view.activeTintColor = UIColor(named: "AccentColor") ?? .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
