import Darwin
import Foundation
import Security

enum PersonalTUNAuthorization {
    static func launcher(helper: URL, engine: URL, session: String) throws -> Process {
        #if MACDPI_PINNED_PERSONAL_TUN
        guard getuid() > 0, getuid() == geteuid() else { throw POSIXError(.EPERM) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode)), nil) == errSecSuccess else {
            throw POSIXError(.EPERM)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, stagingProgram, "MacDPI", helper.path, engine.path,
                             PersonalTUNBuildPins.helper, PersonalTUNBuildPins.engine, session, String(getuid())]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }

    private static let script = """
    on run launchArguments
        set commandText to "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "
        repeat with argumentValue in launchArguments
            set commandText to commandText & quoted form of (contents of argumentValue) & " "
        end repeat
        try
            do shell script commandText with administrator privileges
            return "FINISHED"
        on error number -128
            return "CANCELLED"
        end try
    end run
    """

    // The shell's first argument is its label. Copies are read as the requesting
    // user, written into a root-only directory, and pinned before execution.
    private static let stagingProgram = """
    set -eu
    umask 077
    stage=$(/usr/bin/mktemp -d /private/var/run/macdpi-stage.XXXXXXXX)
    trap '/bin/rm -f "$stage/MacDPITUNHelper" "$stage/MacDPITUNEngine"; /bin/rmdir "$stage"' EXIT
    trap 'exit 1' HUP INT TERM
    requester="$6"
    copy_pinned() {
        /usr/bin/sudo -n -u "#$requester" -- /usr/bin/perl -e 'alarm 8; exec @ARGV or exit 126' /usr/bin/head -c 33554433 "$1" > "$2"
        digest=$(/usr/bin/shasum -a 256 "$2")
        test "$(printf '%s' "$digest" | /usr/bin/cut -d ' ' -f 1)" = "$3"
        /bin/chmod 700 "$2"
    }
    copy_pinned "$1" "$stage/MacDPITUNHelper" "$3"
    copy_pinned "$2" "$stage/MacDPITUNEngine" "$4"
    "$stage/MacDPITUNHelper" run-as "$5" "$requester"
    """
}
