import Foundation

/// The in-process half of the panel's crash fence. Objective-C exceptions raised while a tool runs are caught
/// and reported on the panel. Work that parses a network response runs in a helper process instead, because a
/// fatal error in this process would take the editor with it.
enum AIPanelFence {
    static func exception(in body: () -> Void) -> String? {
        AICatchException(body)
    }
}
