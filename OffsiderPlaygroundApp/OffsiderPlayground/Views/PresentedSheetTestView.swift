import PhotosUI
import SwiftUI

/// Presents the system photo picker, which another process draws over the app, so the app's own tree still lists this screen.
struct PresentedSheetTestView: View {
    @State private var state = "Initial"
    @State private var isShowingPicker = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Presented Sheet State: \(state)")
                .accessibilityIdentifier("presented-sheet-test-state")
                .accessibilityValue(state)

            Button("Show Photo Picker") {
                isShowingPicker = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("presented-sheet-test-open")
        }
        .padding()
        .navigationTitle("Presented Sheet Test")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isShowingPicker) {
            PhotoPickerRepresentable { picked in
                state = picked ? "Picked" : "Cancelled"
                isShowingPicker = false
            }
            .ignoresSafeArea()
        }
    }
}

private struct PhotoPickerRepresentable: UIViewControllerRepresentable {
    let finish: (Bool) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(finish: finish)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let finish: (Bool) -> Void

        init(finish: @escaping (Bool) -> Void) {
            self.finish = finish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            finish(!results.isEmpty)
        }
    }
}
