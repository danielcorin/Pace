import Foundation

/// Starter scripts for `pace actions new`.
public enum PaceActionTemplate: String, CaseIterable, Sendable {
    case blank
    case askClaude = "ask-claude"
    case describeImage = "describe-image"

    public var summary: String {
        switch self {
        case .blank: return "A documented shell script to fill in"
        case .askClaude: return "Send the clipboard and your instructions to `claude -p`"
        case .describeImage: return "Describe or extract text from an image with `claude -p`"
        }
    }

    public func contents(title: String) -> String {
        switch self {
        case .blank:
            return """
            #!/bin/zsh
            # @pace.title       \(title)
            # @pace.description What this action does
            # @pace.icon        bolt
            # @pace.accepts     text
            # @pace.argument    Instructions
            # @pace.output      panel
            # @pace.timeout     120
            #
            # Headers (all optional):
            #   accepts   any, text, image, url, files, or a type like public.movie (comma separated)
            #   argument  shows an instructions field; its value is $PACE_ARGUMENT
            #   output    panel (show the result), paste, copy, or silent
            #   icon      any SF Symbol name
            #
            # Input:
            #   $1…               the input files: copied files, else the image, else a text file
            #   stdin             the clipboard text, when there is any
            #   $PACE_INPUT_DIR   staged input plus manifest.json describing every type
            #   $PACE_INPUT_KIND  text, image, url, or files
            #   $PACE_SOURCE_APP  bundle ID of the app you copied from
            #
            # Output:
            #   stdout              the result, rendered as light Markdown
            #   stderr              progress; the last line shows while running
            #   $PACE_OUTPUT_DIR    files written here (the working directory) become attachments
            #   $PACE_STATE_DIR     private scratch space kept for follow-up steps
            #   $PACE_CONTROL_DIR/confirm   write a button title to offer a confirm step
            #   $PACE_CONTROL_DIR/undo      write a button title to offer an undo step
            #   Follow-up steps run this script again with $PACE_STEP set to confirm or undo.
            set -euo pipefail

            case "${PACE_STEP:-run}" in
              run)
                echo "Got $PACE_INPUT_KIND input from ${PACE_SOURCE_APP_NAME:-somewhere}."
                cat
                ;;
            esac

            """
        case .askClaude:
            return """
            #!/bin/zsh
            # @pace.title       \(title)
            # @pace.description Send the clipboard and your instructions to Claude
            # @pace.icon        sparkles
            # @pace.accepts     any
            # @pace.argument    Ask Claude…
            # @pace.timeout     300
            set -euo pipefail

            instructions=${PACE_ARGUMENT:-"Explain this clearly and briefly."}
            echo "Asking Claude…" >&2

            prompt="$instructions

            The input is in these files (read them before answering): $*
            Answer in Markdown. Save any files you create in the current directory."

            claude -p "$prompt" --allowedTools "Read,Write"

            """
        case .describeImage:
            return """
            #!/bin/zsh
            # @pace.title       \(title)
            # @pace.description Describe an image or pull the text out of it
            # @pace.icon        photo.badge.magnifyingglass
            # @pace.accepts     image
            # @pace.argument    What do you want to know? (optional)
            # @pace.timeout     180
            set -euo pipefail

            question=${PACE_ARGUMENT:-"Describe this image. If it contains text, transcribe it."}
            echo "Looking at the image…" >&2
            claude -p "Read the image at $1. $question" --allowedTools "Read"

            """
        }
    }
}

extension PaceActionCatalog {
    /// Writes a new executable action from `template` and returns its URL.
    /// The file name is the name lowercased and hyphenated, plus `.sh`.
    @discardableResult
    public func create(
        named name: String,
        template: PaceActionTemplate = .blank,
        overwrite: Bool = false
    ) throws -> URL {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !stem.isEmpty else {
            throw PaceError.invalidArgument("An action name needs at least one letter or number.")
        }
        try createDirectoryIfNeeded()
        let url = directoryURL.appendingPathComponent(stem.hasSuffix(".sh") ? stem : "\(stem).sh")
        if FileManager.default.fileExists(atPath: url.path), !overwrite {
            throw PaceError.invalidArgument("\(url.path) already exists. Pass --force to replace it.")
        }
        try Data(template.contents(title: title).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
