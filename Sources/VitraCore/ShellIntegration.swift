import Foundation

/// Teaches the shell to tell the terminal where a command begins and ends.
///
/// Without this a terminal sees one undifferentiated stream of bytes: the
/// prompt, what you typed and what the program printed are the same text. The
/// shell marks them with OSC 133 (`A` prompt, `B` input, `C` output, `D` exit),
/// libghostty records that per row, and the gutter is drawn from it.
///
/// Installed by pointing `ZDOTDIR` at a directory of shims that source the
/// user's own files first — the same mechanism Ghostty and iTerm use, and the
/// only one that works for a login shell nobody has edited.
public enum ShellIntegration {
    /// Where the shims live. Under the app's own directory, never in the user's.
    public static var directory: URL {
        Vitra.supportDirectory.appendingPathComponent("shell/zsh", isDirectory: true)
    }

    /// Whether this shell is one the integration knows.
    ///
    /// zsh only for now: bash and fish need their own hooks, and shipping a
    /// half-working shim is worse than shipping none.
    public static func supports(shell: String) -> Bool {
        URL(fileURLWithPath: shell).lastPathComponent == "zsh"
    }

    /// Writes the shims, and returns the environment additions that arm them.
    ///
    /// Returns nothing at all when the shell is not supported or the files
    /// cannot be written: an unarmed integration costs the user a gutter, an
    /// arming that half-works costs them their shell.
    public static func environment(
        shell: String,
        current: [String: String],
        blockSpacing: Bool = true,
        colorPrompt: Bool = true
    ) -> [String: String] {
        guard supports(shell: shell), (try? install()) != nil else { return [:] }

        // Where the user's own zsh files live, so the shims can defer to them.
        let original = current["ZDOTDIR"] ?? current["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        return [
            "ZDOTDIR": directory.path,
            "VITRA_ZDOTDIR": original,
            "VITRA_SHELL_INTEGRATION": "1",
            "VITRA_BLOCK_SPACING": blockSpacing ? "1" : "0",
            "VITRA_PROMPT_COLOR": colorPrompt ? "1" : "0",
        ]
    }

    /// Writes the shim files, skipping any that are already right.
    ///
    /// Rewriting them on every launch would touch four files per window for no
    /// reason, and would fight any editor the user has open on them.
    public static func install() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            let url = directory.appendingPathComponent(name)
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { continue }
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the shims. `ZDOTDIR` is never written to the user's own files, so
    /// this is all there is to undo.
    public static func uninstall() throws {
        try FileManager.default.removeItem(at: directory)
    }

    static let files: [String: String] = [
        ".zshenv": shim(for: ".zshenv"),
        ".zprofile": shim(for: ".zprofile"),
        ".zlogin": shim(for: ".zlogin"),
        ".zshrc": zshrc,
        "vitra-integration.zsh": integration,
    ]

    /// A startup file that runs the user's own and nothing else.
    private static func shim(for name: String) -> String {
        """
        # Written by Vitra. Runs your own \(name), then gets out of the way.
        VITRA_ZDOTDIR=${VITRA_ZDOTDIR:-$HOME}
        [[ -f "$VITRA_ZDOTDIR/\(name)" ]] && source "$VITRA_ZDOTDIR/\(name)"

        """
    }

    private static let zshrc = """
    # Written by Vitra. Runs your own .zshrc, then adds the command marks.
    VITRA_ZDOTDIR=${VITRA_ZDOTDIR:-$HOME}
    [[ -f "$VITRA_ZDOTDIR/.zshrc" ]] && source "$VITRA_ZDOTDIR/.zshrc"

    # Sourced last on purpose: the prompt has to already be whatever your
    # configuration made it before the marks are appended to it.
    [[ -f "${ZDOTDIR}/vitra-integration.zsh" ]] && source "${ZDOTDIR}/vitra-integration.zsh"

    """

    /// OSC 133, the semantic prompt protocol.
    ///
    /// `A` before the prompt, `B` where input starts, `C` where the command's
    /// output starts, `D;<code>` when it is over. Everything is guarded so a
    /// second source, or a shell that already has these hooks, changes nothing.
    private static let integration = """
    # Written by Vitra. Marks where commands start and end (OSC 133), which is
    # what draws the gutter beside each command block.
    [[ -n "${VITRA_INTEGRATION_LOADED}" ]] && return
    VITRA_INTEGRATION_LOADED=1

    zmodload zsh/datetime 2>/dev/null

    autoload -Uz add-zsh-hook

    _vitra_precmd() {
      local exit_code=$?
      if [[ -n "${_vitra_command_running}" ]]; then
        local ms=0
        if [[ -n "${_vitra_command_start}" ]]; then
          ms=$(( (EPOCHREALTIME - _vitra_command_start) * 1000 ))
          ms=${ms%%.*}
        fi
        printf '\\033]133;D;%s\\a' "$exit_code"
        # The same news on Vitra's own channel: the core consumes 133;D, so this
        # is the only copy the app itself ever gets to see.
        printf '\\033]7337;vitra-block;code=%s;ms=%s\\a' "$exit_code" "$ms"
        unset _vitra_command_running _vitra_command_start
      else
        # A bare Return still closes a block; saying so keeps the statuses lined
        # up with the prompts on screen.
        printf '\\033]7337;vitra-block\\a'
      fi
      printf '\\033]133;A\\a'
    }

    _vitra_preexec() {
      printf '\\033]133;C\\a'
      # Vitra's own channel again: the app shows "running" from this, and the
      # elapsed time beside it, until the block closes.
      printf '\\033]7337;vitra-block-start\\a'
      _vitra_command_running=1
      _vitra_command_start=$EPOCHREALTIME
    }

    add-zsh-hook precmd _vitra_precmd
    add-zsh-hook preexec _vitra_preexec

    # The end of the prompt, marked inside %{...%} so zsh knows it takes up no
    # width — without that the line wraps in the wrong place.
    # A prompt with no colour at all is the stock zsh one, and a terminal that
    # cannot tell the prompt from the output is the thing this is here to fix.
    # A prompt the user has styled is left exactly as it is. Checked before the
    # marker below is appended, because that marker is itself an escape.
    if [[ "$VITRA_PROMPT_COLOR" == "1" && "$PS1" != *$'\\033'* && "$PS1" != *"%F"* && "$PS1" != *"%K"* ]]; then
      PS1='%F{green}%n%f%F{8}@%f%F{cyan}%m%f %F{blue}%1~%f %F{magenta}%#%f '
    fi

    if [[ "$PS1" != *"133;B"* ]]; then
      PS1="${PS1}"$'%{\\033]133;B\\a%}'
    fi

    # One blank line before each prompt, so the blocks are separated by space and
    # not only by a hairline. Off when VITRA_BLOCK_SPACING is not 1, and never
    # applied twice.
    if [[ "$VITRA_BLOCK_SPACING" == "1" && "$PS1" != $'\\n'* ]]; then
      PS1=$'\\n'"${PS1}"
    fi

    """
}
