// SPDX-License-Identifier: Apache-2.0

import Foundation
import ObjectiveC

/// Restarts SpringBoard so that tweaks load, as lightly as iOS allows.
///
/// Codling first asks SpringBoard to relaunch itself with a fade to black,
/// through FrontBoard's system service: only SpringBoard restarts, the
/// render server and open apps stay, and SpringBoard saves its state as it
/// goes. When SpringBoard does not restart within a few seconds, the root
/// helper stops it, and launchd starts it again.
enum Respring {
    @MainActor
    static func now() async {
        if let before = springBoardProcess(), askSpringBoardToRelaunch() {
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if springBoardProcess() != before {
                    return
                }
            }
        }
        _ = await Task.detached(priority: .userInitiated) { RootHelper.respring() }.value
    }

    /// SBSRelaunchActionOptions: fade the screen to black while SpringBoard
    /// restarts, without restarting the render server (1 << 0) or showing a
    /// snapshot (1 << 1).
    private static let fadeToBlack: UInt = 1 << 2

    /// Sends SpringBoard an SBSRelaunchAction. False when the private
    /// frameworks or their methods are not what Codling expects.
    private static func askSpringBoardToRelaunch() -> Bool {
        for framework in ["FrontBoardServices", "SpringBoardServices"] {
            dlopen("/System/Library/PrivateFrameworks/\(framework).framework/\(framework)", RTLD_NOW)
        }
        let makeAction = NSSelectorFromString("actionWithReason:options:targetURL:")
        let sharedService = NSSelectorFromString("sharedService")
        let sendActions = NSSelectorFromString("sendActions:withResult:")
        guard let actionClass = NSClassFromString("SBSRelaunchAction"),
              let serviceClass = NSClassFromString("FBSSystemService"),
              let make = class_getClassMethod(actionClass, makeAction),
              let shared = class_getClassMethod(serviceClass, sharedService) else {
            return false
        }
        typealias MakeAction = @convention(c) (AnyClass, Selector, NSString, UInt, NSURL?) -> AnyObject?
        typealias SharedService = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias SendActions = @convention(c) (AnyObject, Selector, NSSet, AnyObject?) -> Void
        return autoreleasepool {
            // A nil address returns to the Lock Screen.
            guard let action = unsafeBitCast(method_getImplementation(make), to: MakeAction.self)(
                      actionClass, makeAction, "respring", fadeToBlack, nil),
                  let service = unsafeBitCast(method_getImplementation(shared), to: SharedService.self)(
                      serviceClass, sharedService),
                  let send = class_getInstanceMethod(object_getClass(service), sendActions) else {
                return false
            }
            unsafeBitCast(method_getImplementation(send), to: SendActions.self)(
                service, sendActions, NSSet(object: action), nil)
            return true
        }
    }

    /// SpringBoard's process identifier; nil when it is not running or the
    /// process list cannot be read.
    static func springBoardProcess() -> pid_t? {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, UInt32(request.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&request, UInt32(request.count), &processes, &size, nil, 0) == 0 else {
            return nil
        }
        for var process in processes.prefix(size / stride) {
            let name = withUnsafeBytes(of: &process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "SpringBoard" {
                return process.kp_proc.p_pid
            }
        }
        return nil
    }
}
