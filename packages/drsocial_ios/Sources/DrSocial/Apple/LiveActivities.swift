#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

/// Hands a Live Activity type's tokens to the platform: the push-to-start token (iOS 17.2+), each running activity's push
/// token, and its end. The type's Swift name is the `type` the platform and the widget extension share.
@available(iOS 16.2, *)
public enum DrSocialLiveActivities {
    /// Starts watching [type]'s tokens for the life of the app. Call once per ActivityAttributes type, after `DrSocial.start`.
    public static func observe<A: ActivityAttributes>(_ type: A.Type, sdk: DrSocial = .shared) {
        let name = String(describing: type)
        if #available(iOS 17.2, *) {
            Task {
                for await token in Activity<A>.pushToStartTokenUpdates {
                    sdk.liveActivity(kind: "start", type: name, token: hexString(token))
                }
            }
        }
        for activity in Activity<A>.activities { follow(activity, name: name, sdk: sdk) }
        Task {
            for await activity in Activity<A>.activityUpdates { follow(activity, name: name, sdk: sdk) }
        }
    }

    private static func follow<A: ActivityAttributes>(_ activity: Activity<A>, name: String, sdk: DrSocial) {
        Task {
            for await token in activity.pushTokenUpdates {
                sdk.liveActivity(kind: "update", type: name, activity: activity.id, token: hexString(token))
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                sdk.liveActivity(kind: "end", type: name, activity: activity.id)
                break
            }
        }
    }
}
#endif
