import SwiftUI

/// Single and double clicks that never hold back the single click.
///
/// SwiftUI's `.onTapGesture(count: 2)` before `.onTapGesture` (on one view, or on a view inside
/// another that takes single clicks) makes every single click wait out the double-click time,
/// about a third of a second, in case a second click comes. Here the single click runs at once
/// and a double-click runs it on the first click, then the double-click action on the second,
/// as the Grid (`GridCollectionView`) and Finder do. Use these instead of
/// `.onTapGesture(count: 2)`; `ClickGestureTests` fails on a new one.
extension View {
    /// `single` on every click, at once; `double` as the second click of a double-click lands.
    func onClick(perform single: @escaping () -> Void, doubleClick double: @escaping () -> Void) -> some View {
        onTapGesture(perform: single)
            .simultaneousGesture(TapGesture(count: 2).onEnded { double() })
    }

    /// A double-click action that doesn't delay a single click on this view or on a view around it.
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture(count: 2).onEnded { action() })
    }
}
