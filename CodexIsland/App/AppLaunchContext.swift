import Darwin
import Foundation

enum AppLaunchContext {
    static var isRunningTests: Bool {
        Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var isDebuggerAttached: Bool {
        debuggerAttached()
    }

    static func configureProcessSignals() {
        signal(SIGPIPE, SIG_IGN)
    }

    static func shouldAutomaticallyCheckForUpdates(
        isRunningTests: Bool,
        isDebuggerAttached: Bool
    ) -> Bool {
        !isRunningTests && !isDebuggerAttached
    }

    private static func debuggerAttached() -> Bool {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &process, &size, nil, 0)
        }

        guard result == 0 else { return false }
        return (process.kp_proc.p_flag & P_TRACED) != 0
    }
}
