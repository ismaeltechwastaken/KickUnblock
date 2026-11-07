import Foundation

public enum KickWebSheetFinishPolicy {
    public static func shouldAutoDismiss(isLoginSheet: Bool, isRecovery: Bool, isSignedIn: Bool) -> Bool {
        !isRecovery && KickLoginNavigation.shouldAutoDismiss(isLoginSheet: isLoginSheet, isSignedIn: isSignedIn)
    }
}
