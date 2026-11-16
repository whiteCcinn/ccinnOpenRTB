import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Main window: simulator on the left, response editor and inspector on the right. Owner: app-shell.
struct MainView: View {
    var body: some View {
        HSplitView {
            Text("Simulator").frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            Text("Response").frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
