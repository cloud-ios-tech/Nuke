// The MIT License (MIT)
//
// Copyright (c) 2015-2024 Alexander Grebenyuk (github.com/kean).

import Foundation
import UIKit

/// A task performed by the ``ImagePipeline``.
///
/// The pipeline maintains a strong reference to the task until the request
/// finishes or fails; you do not need to maintain a reference to the task unless
/// it is useful for your app.
public final class ImageTask: Hashable, CustomStringConvertible, @unchecked Sendable {
    /// An identifier that uniquely identifies the task within a given pipeline.
    /// Unique only within that pipeline.
    public let taskId: Int64

    /// The original request.
    public let request: ImageRequest

    /// Updates the priority of the task, even if it is already running.
    public var priority: ImageRequest.Priority {
        get { sync { _priority } }
        set {
            let didChange: Bool = sync {
                guard _priority != newValue else { return false }
                _priority = newValue
                return _state == .running
            }
            guard didChange else { return }
            pipeline?.imageTaskUpdatePriorityCalled(self, priority: newValue)
        }
    }
    private var _priority: ImageRequest.Priority

    /// Returns the current download progress. Returns zeros before the download
    /// is started and the expected size of the resource is known.
    public internal(set) var currentProgress: Progress {
        get { sync { _progress } }
        set { sync { _progress = newValue } }
    }
    private var _progress = Progress(completed: 0, total: 0)

    /// The download progress.
    public struct Progress: Hashable, Sendable {
        /// The number of bytes that the task has received.
        public let completed: Int64
        /// A best-guess upper bound on the number of bytes of the resource.
        public let total: Int64

        /// Returns the fraction of the completion.
        public var fraction: Float {
            guard total > 0 else { return 0 }
            return min(1, Float(completed) / Float(total))
        }

        /// Initializes progress with the given status.
        public init(completed: Int64, total: Int64) {
            self.completed = completed
            self.total = total
        }
    }

    /// The current state of the task.
    public var state: State { sync { _state } }
    private var _state: State = .running

    /// The state of the image task.
    public enum State {
        /// The task is currently running.
        case running
        /// The task has received a cancel message.
        case cancelled
        /// The task has completed (without being canceled).
        case completed
    }

    /// An event produced during the runetime of the task.
    public enum Event: Sendable {
        /// The download progress was updated.
        case progress(Progress)
        /// The pipleine generated a progressive scan of the image.
        case preview(ImageResponse)
        /// The task was cancelled.
        ///
        /// - note: You are guaranteed to receive either `.cancelled` or
        /// `.finished`, but never both.
        case cancelled
        /// The task finish with the given response.
        case finished(Result<ImageResponse, ImagePipeline.Error>)
    }

    var isDataTask = false
    var onEvent: ((Event) -> Void)?
    weak var pipeline: ImagePipeline?

    /// Using it without a wrapper to reduce the number of allocations.
    private let lock: os_unfair_lock_t

    /// Returns the response image.
    public var image: PlatformImage {
        get async throws {
            try await response.image
        }
    }

    // TODO: should it start task lazily or eagerly?

    /// The image response.
    public var response: ImageResponse {
        get async throws {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                self.cancel()
            }
        }
    }

    private var task: ConcurrencyTask<ImageResponse, Swift.Error> {
        guard let pipeline else {
            fatalError() // TODO: what should happen
        }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        // TODO: is this a retain cycle?
        if _context.task == nil {
            _context.task = ConcurrencyTask {
                try await pipeline.response(for: self)
            }
        }
        return _context.task!
    }

    /// The events sent by the pipeline during the task execution.
    public var events: AsyncStream<Event> {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if _context.events == nil { _context.events = AsyncStream.makeStream() }
        return _context.events!.0
    }

    /// The stream of progress updates.
    public var progress: AsyncStream<Progress> {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if _context.progress == nil { _context.progress = AsyncStream.makeStream() }
        return _context.progress!.0
    }

    /// The stream of responses. 
    ///
    /// If the progressive decoding is enabled (see ``ImagePipeline/Configuration-swift.struct/isProgressiveDecodingEnabled``),
    /// the stream contains all of the progressive scans loaded by the pipeline
    /// and finished with the full image.
    public var stream: AsyncThrowingStream<ImageResponse, Swift.Error> {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if _context.progress == nil { _context.stream = AsyncThrowingStream.makeStream() }
        return _context.stream!.0
    }

    private var _context = AsyncContext()

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    init(taskId: Int64, request: ImageRequest) {
        self.taskId = taskId
        self.request = request
        self._priority = request.priority

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    /// Marks task as being cancelled.
    ///
    /// The pipeline will immediately cancel any work associated with a task
    /// unless there is an equivalent outstanding task running.
    public func cancel() {
        if setState(.cancelled) {
            pipeline?.imageTaskCancelCalled(self)
        }
    }

    func process(_ event: Event) {
        onEvent?(event)

        let context = sync { _context }
        context.events?.1.yield(event)
        switch event {
        case .progress(let progress):
            context.progress?.1.yield(progress)
        case .preview(let response):
            context.stream?.1.yield(response)
        case .cancelled:
            context.events?.1.finish()
            context.progress?.1.finish()
            context.stream?.1.finish(throwing: CancellationError())
        case .finished(let result):
            context.events?.1.finish()
            context.progress?.1.finish()
            context.stream?.1.yield(with: result.mapError { $0 })
        }
    }

    @discardableResult func setState(_ state: ImageTask.State) -> Bool {
        assert(state == .cancelled || state == .completed)
        os_unfair_lock_lock(lock)
        guard _state == .running else {
            os_unfair_lock_unlock(lock)
            return false
        }
        _state = state
        os_unfair_lock_unlock(lock)
        return true
    }

    private func sync<T>(_ closure: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return closure()
    }

    private struct AsyncContext {
        typealias Stream = AsyncThrowingStream<ImageResponse, Swift.Error>

        var task: ConcurrencyTask<ImageResponse, Swift.Error>?
        var stream: (Stream, Stream.Continuation)?
        var events: (AsyncStream<Event>, AsyncStream<Event>.Continuation)?
        var progress: (AsyncStream<Progress>, AsyncStream<Progress>.Continuation)?
    }

    // MARK: Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self).hashValue)
    }

    public static func == (lhs: ImageTask, rhs: ImageTask) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    // MARK: CustomStringConvertible

    public var description: String {
        "ImageTask(id: \(taskId), priority: \(_priority), progress: \(currentProgress.completed) / \(currentProgress.total), state: \(state))"
    }
}

@available(*, deprecated, renamed: "ImageTask", message: "Async/Await support was addedd directly to the existing `ImageTask` type")
public typealias AsyncImageTask = ImageTask
