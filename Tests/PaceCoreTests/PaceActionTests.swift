import XCTest
@testable import PaceCore

final class PaceActionTests: XCTestCase {
    private var root: URL!
    private var actionsFolder: URL!
    private var runsFolder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceActionTests-\(UUID().uuidString)", isDirectory: true)
        actionsFolder = root.appendingPathComponent("actions", isDirectory: true)
        runsFolder = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: actionsFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Catalog

    func testCatalogParsesHeadersInAnyCommentStyle() throws {
        try writeAction("calendar.sh", """
        #!/bin/sh
        # @pace.title  Calendar → Events
        # @pace.description Read a screenshot
        # @pace.icon calendar
        # @pace.accepts image, public.movie
        # @pace.argument Extra instructions
        # @pace.output copy
        # @pace.timeout 5m
        echo hi
        """)
        try writeAction("shout.js", """
        #!/usr/bin/env node
        // @pace.accepts: text
        console.log("hi")
        """)

        let actions = PaceActionCatalog(directoryURL: actionsFolder).load()
        XCTAssertEqual(actions.map(\.title), ["Calendar → Events", "Shout"])
        let calendar = try XCTUnwrap(actions.first)
        XCTAssertEqual(calendar.summary, "Read a screenshot")
        XCTAssertEqual(calendar.icon, "calendar")
        XCTAssertEqual(calendar.accepts, [.kind(.image), .type("public.movie")])
        XCTAssertEqual(calendar.argument, "Extra instructions")
        XCTAssertEqual(calendar.output, .copy)
        XCTAssertEqual(calendar.timeout, 300)
        XCTAssertTrue(calendar.isRunnable)
        XCTAssertEqual(actions[1].accepts, [.kind(.text)])
    }

    func testCatalogFlagsProblemsInsteadOfHidingTheAction() throws {
        try writeAction("typo.sh", "#!/bin/sh\n# @pace.acept text\n# @pace.output sometimes\n")
        try writeAction("not-executable.sh", "#!/bin/sh\n# @pace.title Draft\n", executable: false)
        try writeAction("README.md", "Notes about my actions", executable: false)
        try writeAction(".hidden.sh", "#!/bin/sh\n")

        let actions = PaceActionCatalog(directoryURL: actionsFolder).load()
        XCTAssertEqual(actions.map(\.id), ["not-executable.sh", "typo.sh"])
        XCTAssertTrue(actions[0].issues.first?.hasPrefix("Not executable") == true)
        XCTAssertEqual(actions[1].issues.count, 2)
        XCTAssertFalse(actions[1].isRunnable)
    }

    func testActionLookupByFileNameStemOrTitle() throws {
        try writeAction("ask-claude.sh", "#!/bin/sh\n# @pace.title Ask Claude\n")
        let catalog = PaceActionCatalog(directoryURL: actionsFolder)
        XCTAssertEqual(catalog.action(named: "ask-claude")?.id, "ask-claude.sh")
        XCTAssertEqual(catalog.action(named: "ask claude")?.id, "ask-claude.sh")
        XCTAssertEqual(catalog.action(named: "ask-claude.sh")?.id, "ask-claude.sh")
        XCTAssertNil(catalog.action(named: "nope"))
    }

    // MARK: - Matching

    func testRequirementsMatchInputKindsAndExplainMisses() {
        let image = PaceAction(fileURL: URL(fileURLWithPath: "/a"), title: "A", accepts: [.kind(.image)])
        let textOrLink = PaceAction(fileURL: URL(fileURLWithPath: "/b"), title: "B", accepts: [.kind(.text), .kind(.url)])
        let anything = PaceAction(fileURL: URL(fileURLWithPath: "/c"), title: "C")

        let text = ActionInput(text: "hello").summary
        XCTAssertFalse(image.accepts(text))
        XCTAssertEqual(image.unmetRequirementDescription(for: text), "Needs an image")
        XCTAssertTrue(textOrLink.accepts(text))
        XCTAssertTrue(anything.accepts(.init()))

        let png = ActionInput(representations: [.init(typeIdentifier: "public.png", data: Data([1]))]).summary
        XCTAssertTrue(image.accepts(png))
        XCTAssertEqual(textOrLink.unmetRequirementDescription(for: png), "Needs text or a link")

        let link = ActionInput(text: "https://example.com/page").summary
        XCTAssertEqual(link.kinds, [.text, .url])
        XCTAssertEqual(link.primaryKind, .url)
    }

    func testCopiedFilesMatchByTypeConformance() {
        let movie = fileInput("/tmp/clip.mov")
        let summary = movie.summary
        XCTAssertEqual(summary.kinds, [.files])
        XCTAssertTrue(summary.satisfies(.type("public.movie")))
        XCTAssertFalse(summary.satisfies(.kind(.image)))
        XCTAssertTrue(fileInput("/tmp/shot.png").summary.satisfies(.kind(.image)))
    }

    func testSearchMatchesTitleDescriptionAndAcceptedKinds() {
        let action = PaceAction(
            fileURL: URL(fileURLWithPath: "/x/cal.sh"),
            title: "Calendar Events",
            summary: "Adds events from a screenshot",
            accepts: [.kind(.image)]
        )
        XCTAssertTrue(action.matches(query: "cal"))
        XCTAssertTrue(action.matches(query: "screenshot events"))
        XCTAssertTrue(action.matches(query: "image"))
        XCTAssertFalse(action.matches(query: "text"))
    }

    // MARK: - Running

    func testTextInputArrivesOnStdinArgumentsAndEnvironment() async throws {
        let action = try loadAction("echo.sh", """
        #!/bin/sh
        # @pace.accepts text
        # @pace.argument Instructions
        echo "kind=$PACE_INPUT_KIND arg=$PACE_ARGUMENT step=$PACE_STEP"
        echo "file=$(cat "$1")"
        echo "stdin=$(cat)"
        echo "cwd=$(pwd -P)"
        echo "source=$PACE_SOURCE_APP"
        """)
        let session = try makeSession(
            action,
            input: ActionInput(text: "hello world", source: ClipboardSource(kind: .application, name: "Notes", bundleIdentifier: "com.apple.Notes")),
            argument: "be brief"
        )
        let (stdout, result) = await collect(session.start(.run))
        XCTAssertEqual(result.termination, .exited(0))
        let lines = stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "kind=text arg=be brief step=run")
        XCTAssertEqual(lines[1], "file=hello world")
        XCTAssertEqual(lines[2], "stdin=hello world")
        XCTAssertTrue(lines[3].hasSuffix("/runs/\(session.id.uuidString)/output"), lines[3])
        XCTAssertEqual(lines[4], "source=com.apple.Notes")
    }

    func testImageInputIsStagedAsPNGWithManifest() async throws {
        let action = try loadAction("img.sh", """
        #!/bin/sh
        # @pace.accepts image
        echo "$1"
        cat "$PACE_INPUT_DIR/manifest.json"
        """)
        let tiff = try XCTUnwrap(Self.tinyTIFF())
        let session = try makeSession(action, input: ActionInput(representations: [
            .init(typeIdentifier: "public.tiff", data: tiff),
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("caption".utf8))
        ]))
        let (stdout, result) = await collect(session.start(.run))
        XCTAssertEqual(result.termination, .exited(0))
        let firstLine = String(stdout.split(separator: "\n").first ?? "")
        XCTAssertTrue(firstLine.hasSuffix("/input/input.png"), firstLine)
        let png = try Data(contentsOf: URL(fileURLWithPath: firstLine))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        let manifestData = try Data(contentsOf: session.directory.inputURL.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["kind"] as? String, "image")
        XCTAssertEqual(manifest["kinds"] as? [String], ["text", "image"])
    }

    func testOutputFilesBecomeAttachmentsAndControlFilesOfferSteps() async throws {
        let action = try loadAction("steps.sh", """
        #!/bin/sh
        if [ "$PACE_STEP" = confirm ]; then
          echo "confirmed $(cat "$PACE_STATE_DIR/plan")"
          echo "Remove it" > "$PACE_CONTROL_DIR/undo"
          exit 0
        fi
        echo "the plan" > "$PACE_STATE_DIR/plan"
        printf 'BEGIN:VCALENDAR\\nEND:VCALENDAR\\n' > events.ics
        echo "Add 2 events" > "$PACE_CONTROL_DIR/confirm"
        echo "preview"
        """)
        let session = try makeSession(action, input: .empty)
        let (firstOutput, first) = await collect(session.start(.run))
        XCTAssertEqual(firstOutput, "preview\n")
        XCTAssertEqual(first.attachments.map(\.name), ["events.ics"])
        XCTAssertEqual(first.confirmTitle, "Add 2 events")
        XCTAssertNil(first.undoTitle)

        let (secondOutput, second) = await collect(session.start(.confirm))
        XCTAssertEqual(secondOutput, "confirmed the plan\n")
        XCTAssertNil(second.confirmTitle, "Offers are cleared before each step")
        XCTAssertEqual(second.undoTitle, "Remove it")
    }

    func testFailureReportsExitStatusAndStderr() async throws {
        let action = try loadAction("fail.sh", "#!/bin/sh\necho 'something broke' >&2\nexit 3\n")
        let session = try makeSession(action, input: .empty)
        var stderr = ""
        var result: ActionStepResult?
        for await event in session.start(.run) {
            switch event {
            case .stderr(let text): stderr += text
            case .finished(let finished): result = finished
            case .stdout: break
            }
        }
        XCTAssertEqual(result?.termination, .exited(3))
        XCTAssertEqual(stderr, "something broke\n")
    }

    func testCancelStopsTheWholeProcessGroup() async throws {
        let marker = root.appendingPathComponent("child-survived")
        let action = try loadAction("slow.sh", """
        #!/bin/sh
        ( sleep 3; touch '\(marker.path)' ) &
        echo started
        sleep 30
        """)
        let session = try makeSession(action, input: .empty)
        let stream = session.start(.run)
        var result: ActionStepResult?
        for await event in stream {
            if case .stdout = event { session.cancel() }
            if case .finished(let finished) = event { result = finished }
        }
        XCTAssertEqual(result?.termination, .cancelled)
        try await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The background child should be killed too")
    }

    func testTimeoutTerminatesTheRun() async throws {
        let action = try loadAction("hang.sh", "#!/bin/sh\n# @pace.timeout 0.5\nsleep 30\n")
        let session = try makeSession(action, input: .empty)
        let started = Date()
        let (_, result) = await collect(session.start(.run))
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testIncompatibleInputIsRejectedBeforeRunning() throws {
        let action = try loadAction("img.sh", "#!/bin/sh\n# @pace.accepts image\n")
        XCTAssertThrowsError(try makeSession(action, input: ActionInput(text: "words"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Needs an image"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runsFolder.path)
            && (try? FileManager.default.contentsOfDirectory(atPath: runsFolder.path).isEmpty) == false)
    }

    func testDiscardRemovesTheRunFolder() throws {
        let action = try loadAction("noop.sh", "#!/bin/sh\n")
        let session = try makeSession(action, input: ActionInput(text: "secret"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.url.path))
        session.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.url.path))
    }

    func testSplitMultibyteOutputIsReassembled() async throws {
        let action = try loadAction("emoji.sh", """
        #!/bin/sh
        printf '\\360\\237'; sleep 0.2; printf '\\230\\200 done\\n'
        """)
        let (stdout, _) = await collect(try makeSession(action, input: .empty).start(.run))
        XCTAssertEqual(stdout, "😀 done\n")
    }

    func testRunawayOutputIsCappedWithoutBlockingTheScript() async throws {
        let action = try loadAction("flood.sh", """
        #!/bin/sh
        # @pace.timeout 20
        head -c 6000000 /dev/zero | tr '\\0' 'x'
        echo done >&2
        """)
        let session = try makeSession(action, input: .empty)
        var stdout = ""
        var stderr = ""
        var result: ActionStepResult?
        for await event in session.start(.run) {
            switch event {
            case .stdout(let text): stdout += text
            case .stderr(let text): stderr += text
            case .finished(let finished): result = finished
            }
        }
        XCTAssertEqual(result?.termination, .exited(0))
        XCTAssertLessThanOrEqual(stdout.utf8.count, ActionProcess.outputLimit + 64)
        XCTAssertTrue(stdout.hasSuffix("[Output truncated by Pace]\n"))
        XCTAssertEqual(stderr, "done\n")
    }

    func testBackgroundChildCanBeStoppedAfterTheScriptExits() async throws {
        let marker = root.appendingPathComponent("late-child")
        let action = try loadAction("detach.sh", """
        #!/bin/sh
        ( sleep 2; touch '\(marker.path)' ) >/dev/null 2>&1 &
        echo leaving
        """)
        let session = try makeSession(action, input: .empty)
        let (_, result) = await collect(session.start(.run))
        XCTAssertEqual(result.termination, .exited(0))
        session.discard(waitingUpTo: 1)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLargeUnreadStdinDoesNotHoldTheRunOpen() async throws {
        let action = try loadAction("ignore.sh", "#!/bin/sh\n# @pace.accepts text\necho ok\n")
        let session = try makeSession(action, input: ActionInput(text: String(repeating: "y", count: 1_000_000)))
        let (stdout, result) = await collect(session.start(.run))
        XCTAssertEqual(stdout, "ok\n")
        XCTAssertEqual(result.termination, .exited(0))
    }

    func testReleaseInputKeepsOnlyAttachments() async throws {
        let action = try loadAction("out.sh", "#!/bin/sh\necho hi > note.txt\n")
        let session = try makeSession(action, input: ActionInput(text: "secret"))
        _ = await collect(session.start(.run))
        session.releaseInput()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.outputURL.appendingPathComponent("note.txt").path))
    }

    func testLoginShellParserReadsAfterMarker() {
        let output = "motd noise\n__PACE_ENVIRONMENT__PATH=/a:/b\0HOME=/Users/x\0MULTI=line1\nline2\0"
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed?["PATH"], "/a:/b")
        XCTAssertEqual(parsed?["MULTI"], "line1\nline2")
        XCTAssertNil(LoginShellEnvironment.parse("no marker"))
        let fallback = LoginShellEnvironment.fallback(base: ["PATH": "/usr/bin"], homeDirectory: URL(fileURLWithPath: "/Users/x"))
        XCTAssertTrue(fallback["PATH"]?.hasPrefix("/Users/x/.local/bin:") == true)
        XCTAssertTrue(fallback["PATH"]?.hasSuffix(":/usr/bin") == true)
    }

    // MARK: - Helpers

    private func writeAction(_ name: String, _ contents: String, executable: Bool = true) throws {
        let url = actionsFolder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    private func loadAction(_ name: String, _ contents: String) throws -> PaceAction {
        try writeAction(name, contents)
        return try XCTUnwrap(PaceActionCatalog(directoryURL: actionsFolder).action(named: name))
    }

    private func makeSession(_ action: PaceAction, input: ActionInput, argument: String = "") throws -> ActionRunSession {
        try ActionRunSession(
            action: action,
            input: input,
            argument: argument,
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            root: runsFolder
        )
    }

    private func collect(_ stream: AsyncStream<ActionRunEvent>) async -> (String, ActionStepResult) {
        var stdout = ""
        var result = ActionStepResult(step: .run, termination: .cancelled, attachments: [])
        for await event in stream {
            switch event {
            case .stdout(let text): stdout += text
            case .stderr: break
            case .finished(let finished): result = finished
            }
        }
        return (stdout, result)
    }

    private func fileInput(_ path: String) -> ActionInput {
        ActionInput(representations: [
            .init(typeIdentifier: "public.file-url", data: Data(URL(fileURLWithPath: path).absoluteString.utf8))
        ])
    }

    private static func tinyTIFF() -> Data? {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context?.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
