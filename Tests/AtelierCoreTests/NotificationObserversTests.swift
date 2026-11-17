import Foundation
import XCTest
@testable import AtelierCore

/// AT-076 M4: observers kept in a `NotificationObservers` stop when it goes or is emptied.
final class NotificationObserversTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        var value = 0
    }

    func testObserversAreRemovedWithTheirOwner() {
        let center = NotificationCenter()
        let name = Notification.Name("AtelierTest.ping")
        let count = Count()
        var observers: NotificationObservers? = NotificationObservers()
        observers?.observe(name, center: center, queue: nil) { _ in count.value += 1 }
        center.post(name: name, object: nil)
        XCTAssertEqual(count.value, 1)
        observers = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(count.value, 1, "gone with its owner")
    }

    func testRemoveAll() {
        let center = NotificationCenter()
        let name = Notification.Name("AtelierTest.ping")
        let count = Count()
        let observers = NotificationObservers()
        observers.observe(name, center: center, queue: nil) { _ in count.value += 1 }
        observers.observe(name, center: center, queue: nil) { _ in count.value += 1 }
        XCTAssertEqual(observers.count, 2)
        observers.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(observers.count, 0)
    }
}
