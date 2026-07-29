# Services Code Review

## Summary

The services layer is in good overall shape: the concurrency model is coherent
(`@MainActor` + `@Observable` / `ObservableObject` used consistently, actors
where appropriate, async/await throughout), and there are no outright
correctness crashes. The dominant problems are (1) a mix of the old
`ObservableObject`/`@Published`/`Combine` pattern and the new `@Observable`
pattern in the same codebase — creating subtle API-surface inconsistencies, (2)
`URLSession.shared` used without timeout configuration on every network call,
(3) a handful of `try?` calls that silently swallow actionable errors, and (4)
two `Task {}` fire-and-forget chains that escape structured concurrency and
would be hard to cancel.

---

## File-by-File Findings

### APIClient.swift
**Severity: Medium**

#### Issues

- **[line 10] Warning — `ObservableObject` on a `@MainActor` class with no
  `@Published` properties.** `APIClient` is declared `ObservableObject` but
  publishes nothing. Any SwiftUI view that holds it as `@StateObject` /
  `@ObservedObject` will trigger unnecessary re-renders on every `objectWillChange`
  emission from the Supabase client injected through it. If nothing in the view
  needs to react to property changes, remove the `ObservableObject` conformance
  and hold the client with `@State` or as an environment value. If reactivity is
  needed later, prefer `@Observable` (no `Combine` import required).

- **[lines 47, 66, 80, 98, 116, 128, 144, 163, 177, 196, 213, 232, 249,
  266] Warning — `URLSession.shared` with no timeout.** Every call uses the
  shared session's default 60-second request timeout and no resource timeout.
  On a mobile connection that stalls mid-response (not a connect failure) the
  app can wait the full 60 s with no way to surface progress or cancel. Create
  a private `URLSession` configured with a `URLSessionConfiguration` that sets
  `timeoutIntervalForRequest` (suggest 20 s) and `timeoutIntervalForResource`
  (suggest 60 s), and reuse it across all calls. This also allows injecting a
  mock session for unit tests.

- **[lines 75, 77, 124] Warning — Force-unwrap `!` on `URLComponents.url`.** 
  `comps.url!` on lines 77 and the analogous lines in `sessionStatus` / `results`
  / `nextCull` will crash if `URLComponents` fails to build a URL (e.g. invalid
  base URL at runtime). Use `guard let url = comps.url else { throw ... }` instead.

- **[line 185] Suggestion — `decision: String` parameter.** `submitCull` accepts
  a raw `String` for `decision` when a `CullDecision` enum already exists in the
  project. Accepting `CullDecision` and calling `.rawValue` at the call site (or
  in the body) makes the API type-safe and eliminates the possibility of sending
  an invalid string.

- **[lines 40–268] Suggestion — Repetitive URLRequest construction.** All 13
  endpoints share the same three-line setup (`httpMethod`, `Content-Type`,
  `Authorization`). Extract a `makeRequest(method:path:body:)` helper to reduce
  duplication and make future auth-header changes a single-point edit.

---

### AuthService.swift
**Severity: Medium**

#### Issues

- **[lines 1, 6–9] Warning — `ObservableObject` + `@Published` + `import
  Combine`.** `AuthService` uses the old `ObservableObject` pattern while
  `DecisionStore` and `LocalCardProvider` already use `@Observable`. The
  inconsistency means SwiftUI views must use `@ObservedObject` / `@StateObject`
  for `AuthService` but `@State` for the others, complicating the injection
  story. Migrate to `@Observable @MainActor final class AuthService` and remove
  the `Combine` import.

- **[lines 29–32] Warning — Auth error swallowed as a `String`, not
  propagated.** `signInIfNeeded()` catches all errors, stores
  `error.localizedDescription` in `authError: String?`, and returns `Void`.
  Callers cannot distinguish a network timeout from a permanent auth rejection,
  cannot re-throw, and cannot pattern-match. Either propagate the error (`async
  throws`) or store a typed `AuthError` enum instead of a `String`.

- **[line 30] Suggestion — `print("Auth error: \(error)")` in production
  code.** Replace with `os_log` / `Logger` from the `os` framework so that
  messages appear in Console.app and can be filtered without recompiling.

---

### DecisionStore.swift
**Severity: Low**

#### Issues

- **[line 24] Warning — Unstructured `Task {}` inside `load(sessionId:)`.** The
  persistence write loop is started with a detached-style fire-and-forget `Task`.
  If `DecisionStore` is deallocated before the task completes, the `continuation`
  is finished (via `deinit`) and the stream terminates cleanly — so this is safe
  in practice. However, the task is invisible to callers and cannot be cancelled
  externally (e.g. when the user starts over). Store the `Task` handle:

  ```swift
  private var persistenceTask: Task<Void, Never>?

  func load(sessionId: UUID) async -> [UUID] {
      decisions = await persistence.load(sessionId: sessionId)
      let s = stream; let p = persistence
      persistenceTask = Task { await p.run(stream: s, sessionId: sessionId) }
      return allDecidedIds
  }
  ```

  Call `persistenceTask?.cancel()` from a `teardown()` method so callers can
  shut the store down cleanly.

- **[lines 61–63] Warning — Double `try?` silences file-read errors.** In
  `DecisionPersistence.load`, a corrupted or truncated JSON file returns `[]`
  silently. The user restarts the cull session with no indication that local
  state was lost. Log the decode error at minimum; ideally surface it to the
  caller so the UI can warn the user.

- **[lines 75–87] Suggestion — `try?` on `encoder.encode` in `save`.** An
  encoding failure on `StoredDecision` would silently drop the write. Encoding a
  `Codable` struct should never fail unless there is a programmer error, but
  asserting or logging here would catch bugs earlier.

- **[line 55] Warning — Force-unwrap `!` on `FileManager.urls`.** 
  `fileManager.urls(for:in:).first!` will crash if the Application Support
  directory is unavailable (extremely rare but non-zero on a freshly-provisioned
  device). Use `guard let support = ... else { return URL(fileURLWithPath: "/dev/null") }`
  or propagate the error.

---

### PhotoPipeline.swift
**Severity: Medium**

#### Issues

- **[line 40] Warning — `@Published` on a `@MainActor` class.** `PhotoPipeline`
  is `@MainActor` but still uses `@Published` / `ObservableObject`. Migrate to
  `@Observable` so that SwiftUI only re-renders when the specific observed
  property changes (granular updates) rather than on every
  `objectWillChange.send()`. This is especially important here because
  `registeredCount` can tick once per uploaded photo.

- **[lines 97–101] Warning — Two unstructured `Task {}` blocks created in
  `start()`.** Both tasks are fire-and-forget with no stored handles. If the
  pipeline is replaced (e.g. "start over" flow), the old tasks keep running,
  observing and modifying `items` on the old `PhotoPipeline` instance, and the
  connectivity retry task would yield to the new pipeline's `retryParked`
  method via the closure capture. Store the task handles and cancel them in a
  `cancel()` method:

  ```swift
  private var materializeTask: Task<Void, Never>?
  private var connectivityTask: Task<Void, Never>?

  func start(photos: [PendingPhoto]) {
      ...
      materializeTask = Task { await self.materializeAll() }
      connectivityTask = Task { [weak self] in ... }
  }

  func cancel() {
      materializeTask?.cancel()
      connectivityTask?.cancel()
  }
  ```

- **[lines 82–86] Suggestion — `DispatchQueue(label:qos:)` for NWPathMonitor.**
  The monitor uses a raw `DispatchQueue` started inside `init`. This is the
  correct API for `NWPathMonitor`, so it is not a bug. However, the queue is
  created even when the caller supplies their own `connectivityEvents` stream
  — the `if let connectivityEvents` branch handles this correctly (line 77),
  so no action needed; noting here for awareness.

- **[line 85] Suggestion — `monitor.start(queue:)` with a fresh queue each
  init.** If `PhotoPipeline` is instantiated many times (unlikely but possible
  in tests), each instance creates a new monitor and queue. This is fine in
  production; just ensure the monitor is cancelled in a `deinit` or `cancel()`
  to avoid orphaned threads. Currently `deinit` is absent and the monitor is
  never cancelled.

- **[lines 125–128] Suggestion — `try?` inside `displayImage`.** The `Data`
  load and `UIImage` decode errors are collapsed to `PipelineError.photoUnavailable`.
  This is acceptable for the display path (the UI just skips the card) but a
  debug build assert or `Logger` call would help diagnose corrupted temp files.

- **[lines 279–280] Warning — `try?` silencing file read at upload time.** If
  `Data(contentsOf: fileURL)` fails (e.g. OS evicted the temp file), the photo
  is silently marked `.failed`. Add a `Logger` call here so failures appear in
  Console during QA.

- **[lines 317–318] Suggestion — `try? await Task.sleep` in retry loop.** If the
  task is cancelled, `Task.sleep` will throw `CancellationError`, which `try?`
  discards. This means a cancelled pipeline will still loop through all retry
  delays. Replace with `try await Task.sleep(...)` — let the cancellation
  propagate and break the retry loop.

- **[line 188] Warning — Destructive `removeItem` on parent uploads directory.**
  `prepareSessionDirectory()` deletes the entire `PictalisUploads` parent folder
  on every session start (`try? FileManager.default.removeItem(at: parent)`).
  If two sessions ever run concurrently (unlikely but possible in tests), the
  second start wipes the first session's materialized files mid-upload. Consider
  deleting only the previous session's subdirectory by tracking its ID, or
  enumerating and deleting only stale sessions.

---

### PhotoSource.swift
**Severity: Clean**

No issues found. The file is small, focused, and correct. `PhotoDataLoading` is
properly `Sendable`, `PickerItemLoader` is a value type, and `PendingPhoto`
carries a `Sendable`-constrained existential. This is a model for how the other
protocol seams in the project should be structured.

---

### PhotoUploadTransport.swift
**Severity: Low**

#### Issues

- **[line 37] Suggestion — `storageError.statusCode == "409"` string
  comparison.** The idempotency check compares a status code as a `String`. If
  the Supabase Swift SDK ever changes `statusCode` to `Int`, this silently stops
  matching. Capture both the string and the integer check, or document why the
  SDK stores it as a `String`, so a future SDK upgrade doesn't silently break
  idempotency.

- **[lines 14–25] Suggestion — No upload progress reporting.** The `upload`
  function uploads potentially large JPEG data in one shot with no progress
  callback. For multi-megabyte images on a slow connection, the UI has no
  visibility. If the Supabase storage SDK supports streaming or progress
  delegates, plumb that through to `PhotoPipeline` so the per-photo progress
  bar (if one is added) has data.

---

### SyncService.swift
**Severity: Low**

#### Issues

- **[lines 73–79] Suggestion — `NotificationCenter.default.notifications` Task
  is unstructured.** The foreground-trigger task (listening for
  `didBecomeActiveNotification`) is started with fire-and-forget `Task { @MainActor
  [weak self] in ... }` and there is no stored handle. The task leaks until
  `SyncService` is deallocated. Because `[weak self]` guards the body, this is
  safe (the task will loop forever observing notifications but do nothing once
  `self` is nil). Still, storing the task handle and cancelling it in a
  `teardown()` method is cleaner and consistent with the network monitor task.

- **[lines 84–92] Suggestion — Connectivity monitor `AsyncStream` continuation
  is never finished.** When `SyncService` is deallocated, `monitor` is released
  and the `pathUpdateHandler` stops yielding, but the `stream` AsyncStream
  continuation is never explicitly finished. The task iterating `stream` will
  then hang waiting for the next element. Capture the continuation and call
  `continuation.finish()` in a `teardown()` or `deinit` method.

- **[lines 127–130] Suggestion — Retry loop gives up silently.** When all
  backoff attempts are exhausted, `performDrain` returns without updating any
  state. The failed decisions remain pending, which is correct (they'll be
  retried on the next trigger), but there is no log or observable error state
  for debugging. Add a `Logger` call on final failure.

- **[line 129] Suggestion — `try? await Task.sleep` discards `CancellationError`
  in retry loop.** Same issue as in `PhotoPipeline`: if the drain task is
  cancelled mid-sleep, the cancellation is swallowed and the retry loop
  continues. Use `try await Task.sleep(...)` and let the error propagate.

---

### LocalCardProvider.swift
**Severity: Low**

#### Issues

- **[lines 31, 34–40] Warning — `nonisolated(unsafe) var memoryWarningObserver`
  with a `NotificationCenter` closure-based observer.** Using `nonisolated(unsafe)`
  is a smell: it tells the compiler "trust me, I'm managing this safely" — but
  the observer closure captures `[weak self]` and hops back to `@MainActor` via
  `Task { @MainActor [weak self] in ... }`, which is correct. However, the
  `nonisolated(unsafe)` attribute is only needed because the legacy
  `addObserver(forName:object:queue:using:)` API returns `NSObjectProtocol`,
  which is not `Sendable`. Modernize to the `AsyncStream`-based pattern used by
  `SyncService` (lines 84–92 there) to eliminate the unsafe annotation
  entirely:

  ```swift
  // In init or start():
  Task { @MainActor [weak self] in
      for await _ in NotificationCenter.default.notifications(
          named: UIApplication.didReceiveMemoryWarningNotification
      ) {
          self?.handleMemoryWarning()
      }
  }
  ```

  This removes the `NSObjectProtocol` token, the `deinit` `removeObserver` call,
  and the `nonisolated(unsafe)` suppression.

- **[line 61, 74, 80] Warning — Unstructured `Task {}` calls with no stored
  handles.** `start()` and `advance()` and `retry()` each fire background `fill`
  tasks that are not stored. If the provider is torn down mid-fill (e.g. user
  exits the cull view), tasks continue to execute, writing to `queue` and
  `state`. Because all mutations are `@MainActor`, there is no data race, but
  the orphaned tasks do unnecessary work. Store a single `fillTask: Task<Void,
  Never>?` and cancel it on teardown.

- **[line 99] Suggestion — Silent `continue` on image load failure.** When
  `pipeline.displayImage(for:)` throws, the card is silently skipped. This is
  the right behavior for a dropped or failed photo, but worth a `Logger` call
  at debug level so unexpected failures surface during QA.

---

## Cross-Cutting Themes

### 1. Mixed `ObservableObject` / `@Observable` patterns

`APIClient`, `AuthService`, and `PhotoPipeline` use the old `ObservableObject` +
`@Published` + `Combine` pattern. `DecisionStore` and `LocalCardProvider` use
the modern `@Observable` macro. This inconsistency means callers must use
different property wrappers (`@StateObject`/`@ObservedObject` vs `@State`) and
import `Combine` unnecessarily. Standardize on `@Observable` throughout — it is
available from iOS 17, which is already the project's deployment target.

### 2. Unstructured `Task {}` fire-and-forget without stored handles

`DecisionStore.load`, `PhotoPipeline.start`, `LocalCardProvider.start` /
`advance` / `retry`, and `SyncService.startObservers` all create `Task {}`
blocks without storing the handle. None of these are bugs today (most capture
`[weak self]` or are protected by `@MainActor`), but they prevent clean
shutdown and make testing harder. The pattern to adopt: store handles, cancel in
a `teardown()` method.

### 3. `URLSession.shared` with no timeout

Every HTTP call in `APIClient` uses `URLSession.shared` with its default 60-second
timeout. On a mobile connection that stalls after the TCP handshake, these calls
can hang for up to a minute with no indication. A shared private `URLSession`
with explicit timeouts is a one-line fix in `APIClient`.

### 4. `try?` swallowing actionable errors

- `DecisionPersistence.load` (decode failure → silent empty state)
- `PhotoPipeline.uploadAndMarkUploaded` (file read failure → silent `.failed`)
- `PhotoPipeline.withRetries` sleep (`CancellationError` discarded)
- `SyncService.performDrain` sleep (same)
- `DecisionPersistence.save` (encode failure → silent dropped write)

Use `Logger` (os framework) at minimum; surface to UI where user impact is
possible.

### 5. Force-unwraps on URL construction

`APIClient` uses `!` on `URLComponents.url` in three places (lines 75, 77,
124-equivalent). These should be replaced with throwing guard statements.

---

## Priority Fix List

**Fix first (correctness / crash risk):**

1. **APIClient lines 77, 124-equiv** — Replace `comps.url!` force-unwraps with
   `guard let url = comps.url else { throw ... }`.
2. **DecisionPersistence line 55** — Replace `fileManager.urls(...).first!` with
   a guarded assignment.
3. **PhotoPipeline line 188** — Scope the directory deletion to only the previous
   session's subdirectory, not the entire parent.
4. **PhotoPipeline / SyncService** — Replace `try? await Task.sleep` in retry
   loops with `try await Task.sleep` so `CancellationError` propagates.

**Fix second (degraded behavior / silent data loss):**

5. **APIClient** — Replace `URLSession.shared` with a private session configured
   with 20 s request / 60 s resource timeouts.
6. **AuthService** — Propagate auth errors to callers (or type the stored error)
   instead of storing a `String`.
7. **DecisionPersistence.load** — Log decode failures; do not silently return `[]`.
8. **PhotoPipeline / LocalCardProvider** — Store `Task` handles and add `cancel()`
   / `teardown()` methods.

**Fix last (modernization / maintainability):**

9. **AuthService + PhotoPipeline** — Migrate from `ObservableObject`/`@Published`
   to `@Observable` (and remove `import Combine` from `AuthService`).
10. **LocalCardProvider** — Replace closure-based `NotificationCenter` observer
    with async `notifications(named:)` stream to eliminate `nonisolated(unsafe)`.
11. **APIClient** — Extract a `makeRequest(method:path:body:)` helper to
    de-duplicate the 13 identical endpoint setups.
12. **APIClient `submitCull`** — Change `decision: String` parameter to
    `decision: CullDecision` for type safety.
