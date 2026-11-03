import CaptureCore
import Foundation

// PipelineBench — Milestone A headless loopback benchmark.
//
//   PipelineBench [--seconds 10] [--mode synthetic|capture] [--bitrate 3000] [--loss 0] [--width 1280 --height 720] [--fps 60]
//
// Exit codes: 0 ok, 1 run failed (setup error or nothing decoded), 2 Screen Recording permission missing (capture
// mode; never prompts), 64 usage error. The last stdout line is a machine-readable `RESULT key=value ...` line.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let options: BenchOptions
do {
    options = try BenchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("PipelineBench: \(error)\n\n\(BenchOptions.usage)", code: 64)
}

if options.help {
    print(BenchOptions.usage)
    exit(0)
}
if options.selfTest {
    exit(SelfTest.run())
}

let result: BenchResult
do {
    switch options.mode {
    case .synthetic:
        result = try BenchRunner.runSynthetic(options)
    case .capture:
        guard ScreenCapturePermission.isGranted() else {
            print("""
            PipelineBench: Screen Recording permission is not granted to this process (or its parent terminal).
            Capture mode does not request it. Grant it in System Settings > Privacy & Security >
            Screen & System Audio Recording for the app running this command, relaunch it, and retry.
            Synthetic mode (--mode synthetic) needs no permission.
            RESULT mode=capture status=permission_missing
            """)
            exit(2)
        }
        result = try await BenchRunner.runCapture(options)
    }
} catch {
    fail("PipelineBench: \(error)", code: 1)
}

print(result.render())
exit(result.framesDecoded > 0 ? 0 : 1)
