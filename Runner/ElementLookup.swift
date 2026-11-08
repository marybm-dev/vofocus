import XCTest

/// Turns element queries into XCUIElements, and the app into a JSON tree agents can
/// read to decide what to tap.
@MainActor
enum ElementLookup {
    static func resolve(_ query: ElementQuery, in app: XCUIApplication) throws -> XCUIElement {
        guard query.identifier != nil || query.label != nil || query.type != nil else {
            throw RunnerError.badRequest("element needs an identifier, a label or a type")
        }
        let type = try elementType(named: query.type)
        var predicates: [NSPredicate] = []
        if let identifier = query.identifier {
            predicates.append(NSPredicate(format: "identifier == %@", identifier))
        }
        if let label = query.label {
            predicates.append(NSPredicate(format: "label == %@", label))
        }
        var matches = app.descendants(matching: type)
        if !predicates.isEmpty {
            matches = matches.matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
        }
        let element = matches.element(boundBy: query.index ?? 0)
        guard element.waitForExistence(timeout: query.timeout ?? 3) else {
            throw RunnerError.elementNotFound(query)
        }
        return element
    }

    static func tree(of app: XCUIApplication) throws -> TreeNode {
        TreeNode(try app.snapshot())
    }

    private static func elementType(named name: String?) throws -> XCUIElement.ElementType {
        guard let name else { return .any }
        guard let type = typesByName[name] else {
            throw RunnerError.badRequest(
                "unknown element type \"\(name)\"; known: \(typesByName.keys.sorted().joined(separator: ", "))")
        }
        return type
    }

    static let typesByName: [String: XCUIElement.ElementType] = [
        "any": .any, "other": .other, "application": .application, "window": .window,
        "alert": .alert, "sheet": .sheet, "button": .button, "link": .link,
        "staticText": .staticText, "textField": .textField, "secureTextField": .secureTextField,
        "searchField": .searchField, "textView": .textView, "image": .image, "icon": .icon,
        "cell": .cell, "table": .table, "collectionView": .collectionView,
        "scrollView": .scrollView, "navigationBar": .navigationBar, "tabBar": .tabBar,
        "toolbar": .toolbar, "switch": .switch, "toggle": .toggle, "slider": .slider,
        "stepper": .stepper, "segmentedControl": .segmentedControl, "picker": .picker,
        "pickerWheel": .pickerWheel, "keyboard": .keyboard, "key": .key, "menu": .menu,
        "menuItem": .menuItem, "progressIndicator": .progressIndicator,
        "activityIndicator": .activityIndicator, "pageIndicator": .pageIndicator,
        "webView": .webView, "map": .map,
    ]

    static let namesByType: [XCUIElement.ElementType: String] =
        Dictionary(uniqueKeysWithValues: typesByName.map { ($1, $0) })
}

/// One element in the app's UI tree. Empty fields are left out.
struct TreeNode: Encodable {
    let type: String
    let identifier: String?
    let label: String?
    let value: String?
    /// [x, y, width, height] in points.
    let frame: [Double]
    let children: [TreeNode]?

    @MainActor
    init(_ snapshot: any XCUIElementSnapshot) {
        type = ElementLookup.namesByType[snapshot.elementType] ?? "type\(snapshot.elementType.rawValue)"
        identifier = snapshot.identifier.isEmpty ? nil : snapshot.identifier
        label = snapshot.label.isEmpty ? nil : snapshot.label
        if let value = snapshot.value.map({ String(describing: $0) }), !value.isEmpty {
            self.value = value
        } else {
            value = nil
        }
        let f = snapshot.frame
        frame = [f.origin.x, f.origin.y, f.size.width, f.size.height].map { Double($0) }
        let kids = snapshot.children.map { TreeNode($0) }
        children = kids.isEmpty ? nil : kids
    }
}
