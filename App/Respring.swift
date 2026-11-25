// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Restarts SpringBoard so that tweaks load, the moment the user asks.
///
/// SpringBoard runs as mobile, as Codling does, so Codling stops it itself
/// with SIGKILL and launchd starts it again at once. Only SpringBoard
/// restarts: since iOS 15, open apps close only when backboardd restarts,
/// which sbreload does and Codling does not. When the signal cannot be sent,
/// the root helper stops SpringBoard instead.
enum Respring {
    static func now() async {
        if let springBoard = springBoardProcess(), kill(springBoard, SIGKILL) == 0 {
            return
        }
        _ = await Task.detached(priority: .userInitiated) { RootHelper.respring() }.value
    }

    /// SpringBoard's process identifier; nil when it is not running or the
    /// process list cannot be read.
    static func springBoardProcess() -> pid_t? {
        processes(named: "SpringBoard").first?.pid
    }

    /// The running processes with a name, and the user each runs as; empty
    /// when the process list cannot be read.
    static func processes(named wanted: String) -> [(pid: pid_t, user: uid_t)] {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, UInt32(request.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&request, UInt32(request.count), &processes, &size, nil, 0) == 0 else {
            return []
        }
        var found: [(pid: pid_t, user: uid_t)] = []
        for var process in processes.prefix(size / stride) {
            let name = withUnsafeBytes(of: &process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == wanted {
                found.append((process.kp_proc.p_pid, process.kp_eproc.e_ucred.cr_uid))
            }
        }
        return found
    }
}
