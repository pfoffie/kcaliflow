import Foundation

struct AppVersionInfo {
    let version: String
    let build: String
    let buildDate: Date?

    static var current: AppVersionInfo {
        let bundle = Bundle.main
        let executableURL = bundle.executableURL
        let attributes = executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)
        }
        let buildDate = (attributes?[.modificationDate] as? Date)
            ?? (attributes?[.creationDate] as? Date)

        return AppVersionInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            buildDate: buildDate
        )
    }

    var displayText: String {
        var result = "\(version) (\(build))"
        if let buildDate {
            result += "\n\(buildDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return result
    }
}

