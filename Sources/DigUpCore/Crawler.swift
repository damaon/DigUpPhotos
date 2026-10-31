import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A file the crawler decided to index.
public struct Candidate: Sendable {
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
    public let inode: UInt64
    public let device: UInt64
}

public struct CrawlReport: Sendable {
    public var candidates: [Candidate] = []
    public var skipped: [String: Int] = [:]          // reason → files
    public var skippedFolders: [String: Int] = [:]   // reason → folders not walked into
    public var datasets: [String: Int] = [:]         // folder → files skipped as a dataset
}

/// Walks the chosen folders and applies `Rules`. Reads metadata only, never file contents (except the 600-byte
/// sniff that tells a real MPEG-TS video from a TypeScript file).
public enum Crawler {
    public static func crawl(_ roots: [URL], options: IndexOptions) -> CrawlReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        #if canImport(UniformTypeIdentifiers)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .isUbiquitousItemKey,
                                      .ubiquitousItemDownloadingStatusKey]
        #else
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        #endif
        var report = CrawlReport()
        var projectRoots = Set<String>()
        var found: [Candidate] = []
        var foundPaths = Set<String>()   // a folder inside another root would be walked twice
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })

        for root in roots.map({ $0.standardizedFileURL }) {
            if Rules.isProjectRoot(root.path) {
                projectRoots.insert(root.path)
            }
            // A skip applies inside the chosen folders that contain it: a folder chosen inside a skipped one is
            // walked whole (`FolderSelection`). The walk reports real paths (/private/var, where the root says /var).
            let real = FolderSelection.realPath(root.path)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root.path) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { continue }
            func visit(_ url: URL) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true, values?.isPackage != true {
                    if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                    } else if Rules.isProjectRoot(url.path) {
                        projectRoots.insert(url.path)
                    }
                    return
                }
                if values?.isPackage == true {
                    report.skipped["app or bundle", default: 0] += 1
                    return
                }
                #if canImport(UniformTypeIdentifiers)
                let type = values?.contentType.map(FileType.init)
                #else
                let type = FileType(filenameExtension: url.pathExtension)
                #endif
                let classification = Rules.classify(url, type: type, options: options)
                switch classification {
                case .ignore:
                    report.skipped["other type", default: 0] += 1
                case .skip(let reason):
                    report.skipped[reason, default: 0] += 1
                case .index(let kind):
                    guard let facts = FileFacts(url, values), facts.isRegular else {
                        report.skipped["link or special file", default: 0] += 1
                        return
                    }
                    if facts.inTheCloud {
                        report.skipped["in the cloud, not downloaded", default: 0] += 1
                        return
                    }
                    guard foundPaths.insert(url.path).inserted else { return }
                    found.append(Candidate(path: url.path, kind: kind, size: facts.size, mtime: facts.mtime,
                                           inode: facts.inode, device: facts.device))
                }
            }

            // URL resource values are autoreleased; draining per file keeps a big walk from piling them up (the app
            // crawls on a background queue whose pool only drains when the whole sync is done).
            while let url = drainingPool({ walker.nextObject() as? URL }) {
                drainingPool {
                    visit(url)
                }
            }
        }

        // Inside a code project only screenshots count (assets, fixtures and datasets don't).
        var inProject: [String: Bool] = [:]
        func isInProject(_ folder: String) -> Bool {
            if let known = inProject[folder] { return known }
            let parent = (folder as NSString).deletingLastPathComponent
            let answer = projectRoots.contains(folder) || (parent != folder && parent.count > 1 && isInProject(parent))
            inProject[folder] = answer
            return answer
        }
        var kept: [Candidate] = []
        for file in found {
            if file.kind != .screenshot, isInProject((file.path as NSString).deletingLastPathComponent) {
                report.skipped["inside a code project", default: 0] += 1
            } else {
                kept.append(file)
            }
        }

        if !options.includeDatasets {
            let datasets = Rules.datasetFolders(kept.map {
                (($0.path as NSString).deletingLastPathComponent,
                 (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension, $0.kind)
            }, roots: rootPaths)
            if !datasets.isEmpty {
                report.datasets = datasets
                kept.removeAll { file in
                    let skip = datasets[(file.path as NSString).deletingLastPathComponent] != nil
                        && [.image, .audio, .video].contains(file.kind)
                    if skip { report.skipped["dataset", default: 0] += 1 }
                    return skip
                }
            }
        }
        report.candidates = kept
        return report
    }
}
