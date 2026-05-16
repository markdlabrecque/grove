// SyncEdgeCaseTests.swift
// These tests are nested INSIDE StubNetworkTests (StubNetworkTests.swift) so they
// participate in the outer `.serialized` constraint and do not race other suites
// on `StubURLProtocol`'s static responder.
//
// See the `SyncEdgeCaseTests` struct extension at the bottom of
// StubNetworkTests.swift for the implementation.
//
// NOTE: This file is intentionally empty — the test suite lives as a nested
// struct inside `StubNetworkTests` to share the serialised outer suite.
// Keeping the file in the project ensures it shows up in Xcode's navigator.
