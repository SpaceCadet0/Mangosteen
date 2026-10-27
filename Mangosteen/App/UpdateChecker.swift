import AppKit

/// «Проверить обновления…»: asks GitHub for the latest release and offers to open its page when it is newer
/// than the running version. Nothing is downloaded or installed by the app itself.
enum UpdateChecker {
    static let repository = "SpaceCadet0/Mangosteen"
    private static let latestRelease = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        var version: String { AppVersion.normalized(tagName) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks and shows the answer in an alert: a newer version with Download, up to date, or the error.
    static func checkAndReport() {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error> = Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode(Release.self, from: data)
            }
            DispatchQueue.main.async { report(result) }
        }.resume()
    }

    private static func report(_ result: Result<Release, Error>) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = MangosteenArt.appIcon(size: 128)
        switch result {
        case .success(let release) where AppVersion.isNewer(release.version, than: currentVersion):
            alert.messageText = String(localized: "Доступна версия \(release.version)")
            alert.informativeText = String(localized: "У вас установлена версия \(currentVersion). Скачайте новую со страницы релиза и замените приложение в папке «Программы».")
            alert.addButton(withTitle: String(localized: "Скачать"))
            alert.addButton(withTitle: String(localized: "Позже"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .success:
            alert.messageText = String(localized: "У вас последняя версия")
            alert.informativeText = String(localized: "Mangosteen \(currentVersion) — самая новая версия.")
            alert.runModal()
        case .failure:
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Не удалось проверить обновления")
            alert.informativeText = String(localized: "Проверьте подключение к интернету и попробуйте ещё раз.")
            alert.runModal()
        }
    }
}
