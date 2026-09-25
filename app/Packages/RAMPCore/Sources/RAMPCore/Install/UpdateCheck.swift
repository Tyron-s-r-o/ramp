import Foundation

/// Comparable package version: `8.3.35`, `2.4.68`, `9.7.2`, `9.5.4`, `8.3.35-rc1`.
///
/// Numeric component-wise comparison, missing components = 0 (`9.5` == `9.5.0`); a suffix
/// (`-rc1`, `RC1`) sorts before the release, suffixes compare numerically-aware among themselves.
/// Strings that do not start with a number (`current`, `.staging`) are not versions (`nil`).
public struct PackageVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    /// Pre-release suffix without the leading `-`; `nil` = release.
    public let suffix: String?
    public let description: String

    public init?(_ string: String) {
        let numeric = string.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard !numeric.isEmpty, !numeric.hasSuffix(".") else { return nil }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            components.append(n)
        }
        var rest = string.dropFirst(numeric.count)
        while rest.first == "-" || rest.first == "_" || rest.first == "+" { rest.removeFirst() }
        self.components = components
        self.suffix = rest.isEmpty ? nil : String(rest)
        self.description = string
    }

    private func component(_ i: Int) -> Int { i < components.count ? components[i] : 0 }

    public static func == (a: Self, b: Self) -> Bool {
        let n = max(a.components.count, b.components.count)
        return (0..<n).allSatisfy { a.component($0) == b.component($0) } && a.suffix == b.suffix
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(suffix)
    }

    public static func < (a: Self, b: Self) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) where a.component(i) != b.component(i) {
            return a.component(i) < b.component(i)
        }
        switch (a.suffix, b.suffix) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?): return x.compare(y, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }
}

/// An installed component/branch with a strictly higher version in the manifest.
public struct PackageUpdate: Sendable, Equatable, Hashable, Identifiable {
    public let component: String
    public let branch: String
    public let installed: String
    public let available: String

    public var id: String { "\(component)/\(branch)" }

    public init(component: String, branch: String, installed: String, available: String) {
        self.component = component
        self.branch = branch
        self.installed = installed
        self.available = available
    }
}

/// Detect-only update check (05-05 Task 1). Built on `UpdatePolicy`: only same-branch updates
/// (automatic or offered) — never a new branch or a MySQL migration. Sorted by component, then branch.
public enum UpdateCheck {
    public static func available(manifest: Manifest,
                                 installed: [String: [String: InstalledPackage]]) -> [PackageUpdate] {
        UpdatePolicy.plan(manifest: manifest, installed: installed, settings: UpdateSettings())
            .items
            .filter { $0.kind == .automatic || $0.kind == .offered }
            .compactMap { item in
                item.from.map { PackageUpdate(component: item.component, branch: item.branch,
                                              installed: $0, available: item.to) }
            }
            .sorted {
                $0.component != $1.component
                    ? $0.component < $1.component
                    : UpdatePolicy.branchLess($0.branch, $1.branch)
            }
    }
}
