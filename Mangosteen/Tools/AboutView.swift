import SwiftUI

/// "About Mangosteen": icon, version, a short description and the project link.
struct AboutView: View {
    let close: () -> Void

    static let repositoryURL = URL(string: "https://github.com/SpaceCadet0/Mangosteen")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: MangosteenArt.appIcon(size: 256))
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(verbatim: "Mangosteen").font(.title.weight(.semibold))
                Text(String(localized: "Версия \(version)"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(String(localized: "Конвертация и инструменты для файлов прямо во время перетаскивания: начните тащить файл, нажмите клавишу и бросьте его на дольку колеса. Всё работает на этом Mac, без ограничений."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: Self.repositoryURL) {
                Label(String(localized: "Mangosteen на GitHub"), systemImage: "arrow.up.right.square")
            }
            Text(verbatim: "© 2026 Igor Rusakov (SpaceCadet) · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 380)
    }
}
