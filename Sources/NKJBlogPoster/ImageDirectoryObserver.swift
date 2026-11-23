import Darwin
import Dispatch
import Foundation

/// Observes the directories containing images referenced by the current article.
/// Directory-level events cover Finder deletes, renames, and replacements without
/// holding an open handle to each image file.
@MainActor
final class ImageDirectoryObserver {
    var onChange: (() -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var observedDirectories = Set<URL>()

    func observe(directories: [URL]) {
        let normalizedDirectories = Set(directories.compactMap { directory -> URL? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return directory.resolvingSymlinksInPath().standardizedFileURL
        })
        guard normalizedDirectories != observedDirectories else { return }

        stop()
        observedDirectories = normalizedDirectories

        for directory in normalizedDirectories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.onChange?()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        observedDirectories.removeAll()
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}
