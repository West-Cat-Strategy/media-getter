import Foundation

enum DownloadAuthCommandBuilder {
    static func arguments(for auth: ResolvedDownloadAuth?) -> [String] {
        guard let auth else { return [] }

        switch auth {
        case .browser(let configuration):
            return ["--cookies-from-browser", configuration.ytDLPValue]
        case .cookieFile(let path):
            return ["--cookies", path]
        case .advancedHeaders(let cookieHeader, let userAgent, let headers):
            var arguments = ["--add-header", "Cookie:\(cookieHeader)"]

            if let userAgent {
                arguments.append(contentsOf: ["--user-agent", userAgent])
            }

            for header in headers {
                arguments.append(contentsOf: ["--add-header", "\(header.trimmedName):\(header.trimmedValue)"])
            }

            return arguments
        }
    }
}
