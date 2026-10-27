// expo-ios overlay (local, never upstreamed).
//
// expo-dev-client ships no native sources: its ios/ holds only a podspec that
// aggregates expo-dev-launcher, expo-dev-menu, expo-dev-menu-interface,
// EXManifests and EXUpdatesInterface. Expo's SwiftPM plugin classifies such a
// module as pure Swift and emits a target over ios/, which SwiftPM rejects:
// "target 'expo-dev-client' referenced in product 'expo-dev-client' is empty".
// This file gives that target one (empty) source so the Debug graph resolves.
// The packages it aggregates are autolinked on their own.
