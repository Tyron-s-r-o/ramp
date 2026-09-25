import Foundation
import RAMPCore

// rampctl open phpmyadmin|elasticvue — prints the phpMyAdmin (plan 04-04) / Elasticvue URL.

let openUsageText = "       rampctl open phpmyadmin|elasticvue"

func openCommand(_ args: [String]) async -> Int32 {
    guard args == ["phpmyadmin"] || args == ["elasticvue"] else { usage() }
    if args == ["elasticvue"] { return await openElasticvue() }
    do {
        let config = try await ConfigStore(paths: paths).load()
        guard PhpMyAdminConfigGenerator.isInstalled(config) else {
            err("phpMyAdmin is not installed")
            return 2
        }
        guard config.phpmyadmin.enabled else {
            err("phpMyAdmin is disabled (ramp.json phpmyadmin.enabled)")
            return 2
        }
        let port = config.apache.port
        out("http://localhost\(port == 80 ? "" : ":\(port)")/phpmyadmin/")
        return 0
    } catch {
        err("open: \(error.localizedDescription)")
        return 1
    }
}

/// Exit 2 when Elasticvue or Elasticsearch is not installed (no /elasticvue alias is rendered then).
private func openElasticvue() async -> Int32 {
    do {
        let config = try await ConfigStore(paths: paths).load()
        guard ElasticvueConfigGenerator.isInstalled(config) else {
            err("Elasticvue is not installed (it comes with Elasticsearch: rampctl es install)")
            return 2
        }
        guard ElasticvueConfigGenerator(config: config, paths: paths).site() != nil else {
            err("Elasticsearch \(config.elasticsearch.branch) is not installed")
            return 2
        }
        out(ElasticvueConfigGenerator.url(apachePort: config.apache.port))
        return 0
    } catch {
        err("open: \(error.localizedDescription)")
        return 1
    }
}
