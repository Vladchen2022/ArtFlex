import Foundation

@MainActor
final class AppPresentationState: ObservableObject {
    @Published var isSettingsSheetPresented = false

    func presentSettingsSheet() {
        isSettingsSheetPresented = true
    }

    func dismissSettingsSheet() {
        isSettingsSheetPresented = false
    }
}
