//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

/// Maps element type names in the wire protocol to XCUIElement.ElementType.
/// Public API gives no name lookup, so this table is maintained by hand.
private let typesByName: [String: XCUIElement.ElementType] = [
    "any": .any,
    "other": .other,
    "application": .application,
    "group": .group,
    "window": .window,
    "sheet": .sheet,
    "alert": .alert,
    "dialog": .dialog,
    "button": .button,
    "radioButton": .radioButton,
    "checkBox": .checkBox,
    "popUpButton": .popUpButton,
    "menuButton": .menuButton,
    "toolbarButton": .toolbarButton,
    "popover": .popover,
    "keyboard": .keyboard,
    "key": .key,
    "navigationBar": .navigationBar,
    "tabBar": .tabBar,
    "tabGroup": .tabGroup,
    "toolbar": .toolbar,
    "statusBar": .statusBar,
    "table": .table,
    "cell": .cell,
    "collectionView": .collectionView,
    "slider": .slider,
    "pageIndicator": .pageIndicator,
    "progressIndicator": .progressIndicator,
    "activityIndicator": .activityIndicator,
    "segmentedControl": .segmentedControl,
    "picker": .picker,
    "pickerWheel": .pickerWheel,
    "switch": .switch,
    "toggle": .toggle,
    "link": .link,
    "image": .image,
    "icon": .icon,
    "searchField": .searchField,
    "scrollView": .scrollView,
    "staticText": .staticText,
    "textField": .textField,
    "secureTextField": .secureTextField,
    "datePicker": .datePicker,
    "textView": .textView,
    "menu": .menu,
    "menuItem": .menuItem,
    "map": .map,
    "webView": .webView,
    "stepper": .stepper,
    "tab": .tab,
    "ratingIndicator": .ratingIndicator,
]

private let namesByType: [UInt: String] = Dictionary(
    typesByName.map { ($0.value.rawValue, $0.key) },
    uniquingKeysWith: { first, _ in first }
)

/// The type for a wire name, defaulting to any when the name is nil or unknown.
func elementType(_ name: String?) -> XCUIElement.ElementType {
    guard let name else { return .any }
    return typesByName[name] ?? .any
}

/// The wire name for a type, or the raw value when it has no name in the table.
func typeName(_ type: XCUIElement.ElementType) -> String {
    namesByType[type.rawValue] ?? "type\(type.rawValue)"
}
