import Foundation

enum AppConstants {
    static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    static let displayVersion: String = {
#if DEBUG
        let info = Bundle.main.infoDictionary
        let developmentVersion = info?["RMBDevelopmentVersion"] as? String
        let configuration = info?["RMBBuildConfiguration"] as? String
        let branch = info?["RMBGitBranch"] as? String
        let commit = info?["RMBGitCommit"] as? String
        let timestamp = info?["RMBBuildTimestamp"] as? String

        if let developmentVersion, let configuration, let branch, let commit, let timestamp {
            return "v\(developmentVersion) • \(configuration) • \(branch)@\(commit) • \(timestamp)"
        }
#endif

        guard let bundleVersion else {
            return "-"
        }
        
        return "v\(bundleVersion)"
    }()
    
    static let appName = "Reminders MenuBar"
    static let mainBundleId = "br.com.damascenorafael.reminders-menubar"
    static let launcherBundleId = "br.com.damascenorafael.reminders-menubar-launcher"
}

enum GithubConstants {
    static let repository = "DamascenoRafael/reminders-menubar"
    static let repositoryPage = "https://github.com/\(repository)"
}

#if APPSTORE
enum AppStoreConstants {
    static let appId = "PLACEHOLDER_APP_ID"
    static let appPage = "macappstore://apps.apple.com/app/id\(appId)"
    static let versionCheckUrl = "https://itunes.apple.com/lookup?bundleId=\(AppConstants.mainBundleId)"
}
#endif
