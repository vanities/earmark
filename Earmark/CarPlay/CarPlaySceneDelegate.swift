import CarPlay
import UIKit
import os

/// Instantiated by the system from Info.plist when the phone connects to a car.
/// Requires the `com.apple.developer.carplay-audio` entitlement on device.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CarPlayInterface?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] connected")
        let interface = CarPlayInterface(interfaceController: interfaceController, environment: .shared)
        self.interface = interface
        interface.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Logger.carplay.info("[carplay] disconnected")
        interface?.stop()
        interface = nil
    }
}
