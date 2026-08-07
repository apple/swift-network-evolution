//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
@resultBuilder
public struct StreamDeserializationBuilder<
    T: ~Copyable,
    StateIdentifier: Hashable & Sendable,
    Factory: DeserializerSpanFactory & ~Copyable & ~Escapable
> {
    public typealias Step = StreamDeserializer<T, StateIdentifier, Factory>.Step
    public typealias Steps = [Step]

    public static func buildExpression(_ step: Step) -> Steps {
        [step]
    }

    public static func buildExpression(_ component: Steps) -> Steps {
        component
    }

    public static func buildOptional(_ components: Steps?) -> Steps {
        components ?? []
    }
    public static func buildEither(first: Steps) -> Steps {
        first
    }
    public static func buildEither(second: Steps) -> Steps {
        second
    }
    public static func buildArray(_ results: [Steps]) -> Steps {
        results.flatMap(\.self)
    }

    public static func buildBlock() -> Steps {
        []
    }

    public static func buildPartialBlock(first: Steps) -> Steps {
        first
    }

    public static func buildPartialBlock(accumulated: Steps, next: Steps) -> Steps {
        accumulated + next
    }

    public static func buildFinalResult(_ component: Steps) -> StreamDeserializer<T, StateIdentifier, Factory>.Steps {
        StreamDeserializer<T, StateIdentifier, Factory>.Steps(steps: component)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StreamDeserializerState: ~Copyable {

    /// An associated type that defines hashable identifiers for state-machine steps.
    ///
    /// Use these identifiers to loop and jump between states during deserialization.
    associatedtype StateMachineStepIdentifier: Hashable

    /// Creates a default state.
    init()
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StreamDeserializer<
    T: ~Copyable,
    StateIdentifier: Hashable & Sendable,
    Factory: DeserializerSpanFactory & ~Copyable & ~Escapable
>: ~Copyable {
    public typealias ValueGenerator = () -> T
    public typealias StepBuilder =
        @Sendable (_ read: inout Deserializer<Factory>, _ value: inout T) throws(DeserializationError) -> Void
    public typealias StepLoopBuilder =
        @Sendable (_ read: inout Deserializer<Factory>, _ value: inout T) throws(DeserializationError) -> StepLoopResult
    public typealias StepConditionEvaluator = @Sendable (_ value: inout T) -> Bool
    public typealias StepByteCountEvaluator = @Sendable (_ value: inout T) -> Int
    public typealias StepByteForwarder = @Sendable (_ byteCount: Int, _ factory: inout Factory, _ value: inout T) -> Int

    public struct Steps: Sendable {
        let steps: [Step]

        var count: Int {
            steps.count
        }

        subscript(index: Int) -> Step {
            steps[index]
        }
    }

    public enum StepLoopResult {
        case continueLoop
        case breakLoop
    }

    public enum Step: Sendable {
        case beginState(StateIdentifier)
        case jumpToState(StateIdentifier, StepConditionEvaluator)
        case parse(StepBuilder)
        case parseWhen(StepConditionEvaluator, StepBuilder)
        case parseWhile(StepConditionEvaluator, StepByteCountEvaluator?, StepLoopBuilder)
        case forward(StepByteCountEvaluator, StepByteForwarder)
        case finalize
        case finalizeWhen(StepConditionEvaluator)

        func shouldExecute(for value: inout T) -> Bool {
            switch self {
            case .beginState: return false  // Nothing to do
            case .parse, .finalize, .forward: return true
            case .jumpToState(_, let evaluator): return evaluator(&value)
            case .parseWhen(let evaluator, _): return evaluator(&value)
            case .parseWhile(let evaluator, _, _): return evaluator(&value)
            case .finalizeWhen(let evaluator): return evaluator(&value)
            }
        }

        func byteCount(for value: inout T) -> Int? {
            switch self {
            case .parseWhile(_, let byteCountEvaluator, _): return byteCountEvaluator?(&value) ?? nil
            case .forward(let byteCountEvaluator, _): return byteCountEvaluator(&value)
            default: return nil
            }
        }

        var builder: StepBuilder? {
            switch self {
            case .parse(let builder): return builder
            case .parseWhen(_, let builder): return builder
            default: return nil
            }
        }

        var loopBuilder: StepLoopBuilder? {
            switch self {
            case .parseWhile(_, _, let builder): return builder
            default: return nil
            }
        }

        var byteForwarder: StepByteForwarder? {
            switch self {
            case .forward(_, let forwarder): return forwarder
            default: return nil
            }
        }

        var shouldFinalize: Bool {
            switch self {
            case .finalize, .finalizeWhen: return true
            default: return false
            }
        }

        var jumpToState: StateIdentifier? {
            switch self {
            case .jumpToState(let state, _): return state
            default: return nil
            }
        }

    }

    private var value: T
    private var valueGenerator: ValueGenerator

    // Once set, all parsing fails
    private var storedFailure: DeserializationError?

    private let streamSteps: Steps
    private var stepCursor = 0
    private var stepCount: Int {
        streamSteps.count
    }

    private var currentLoopStepCursor: Int?
    private var stepLoopMaximumBytes: Int?  // Stored value for currentLoopStepCursor, max bytes to parse in loop
    private var stepLoopByteCount: Int?  // Stored value for currentLoopStepCursor, current bytes parsed in loop

    private var currentForwardBytesStepCursor: Int?

    // Stored value for currentForwardBytesStepCursor, total bytes to forward
    private var stepForwardTotalByteCount = 0

    // Stored value for currentForwardBytesStepCursor, current bytes forwarded
    private var stepForwardCurrentByteCount = 0

    fileprivate init(
        _ valueGenerator: @escaping ValueGenerator,
        @StreamDeserializationBuilder<T, StateIdentifier, Factory> _ builder: (_ stream: StreamDeserializer.Type) ->
            Steps
    ) {
        self.valueGenerator = valueGenerator
        self.value = valueGenerator()
        self.streamSteps = builder(StreamDeserializer.self)
    }

    fileprivate init(_ valueGenerator: @escaping ValueGenerator, _ steps: Steps) {
        self.valueGenerator = valueGenerator
        self.value = valueGenerator()
        self.streamSteps = steps
    }

    private mutating func extractValueAndReset() -> T {
        // Reset step cursors
        stepCursor = 0
        currentLoopStepCursor = 0
        currentForwardBytesStepCursor = 0

        // Extract value
        var tempValue = self.valueGenerator()
        swap(&tempValue, &value)
        return tempValue
    }

    private mutating func jumpToState(_ state: StateIdentifier) throws(DeserializationError) {
        for (i, step) in streamSteps.steps.enumerated() {
            if case .beginState(let identifier) = step {
                if identifier == state {
                    stepCursor = i
                    currentLoopStepCursor = nil
                    currentForwardBytesStepCursor = nil
                    return
                }
            }
        }
        throw .parsingFailed
    }

    fileprivate mutating func handleInputInternal(
        _ runStep: (StepBuilder, inout T) -> DeserializationResult,
        _ runStepLoop: (StepLoopBuilder, inout T) -> (DeserializationResult, StepLoopResult),
        _ forwardBytes: (Int, StepByteForwarder, inout T) throws(DeserializationError) -> Int
    ) throws(DeserializationError) -> T? {
        if let storedFailure {
            throw storedFailure
        }
        while stepCursor < stepCount {
            // Check condition before executing builder
            guard streamSteps[stepCursor].shouldExecute(for: &value) else {
                // Ignore this step and move to the next
                stepCursor += 1
                continue
            }
            if let state = streamSteps[stepCursor].jumpToState {
                try jumpToState(state)
                continue
            }
            if let builder = streamSteps[stepCursor].builder {
                let result = runStep(builder, &value)
                switch result {
                case .error(let error):
                    switch error {
                    case .bufferTooShort:
                        // Couldn't complete this step, not enough bytes. Return and don't increment
                        return nil
                    default:
                        // Hard failure, throw
                        storedFailure = error
                        throw error
                    }
                default:
                    // Good case, continue
                    break
                }
            } else if let loopBuilder = streamSteps[stepCursor].loopBuilder {
                if currentLoopStepCursor != stepCursor {
                    // Reset the state for the loop byte counter
                    currentLoopStepCursor = stepCursor
                    stepLoopMaximumBytes = streamSteps[stepCursor].byteCount(for: &value)
                    stepLoopByteCount = 0
                }
                if stepLoopMaximumBytes != 0 {
                    repeat {
                        var (result, loopResult) = runStepLoop(loopBuilder, &value)
                        switch result {
                        case .error(let error):
                            switch error {
                            case .bufferTooShort:
                                // Couldn't complete this step, not enough bytes. Return and don't increment
                                return nil
                            default:
                                // Hard failure, throw
                                storedFailure = error
                                throw error
                            }
                        case .success(let parsedBytes, _):
                            // Increment bytes for this loop iteration
                            self.stepLoopByteCount? += parsedBytes
                            if let stepLoopMaximumBytes, let stepLoopByteCount,
                                stepLoopByteCount >= stepLoopMaximumBytes
                            {
                                // Hit maximum bytes, break the loop
                                loopResult = .breakLoop
                                break
                            }
                        }

                        // Good case, check loop result
                        if case .breakLoop = loopResult {
                            break
                        } else {
                            continue
                        }
                    } while streamSteps[stepCursor].shouldExecute(for: &value)
                }
            } else if let forwarder = streamSteps[stepCursor].byteForwarder {
                if currentForwardBytesStepCursor != stepCursor {
                    // Reset the state for the forwarding byte counter
                    currentForwardBytesStepCursor = stepCursor
                    stepForwardTotalByteCount = streamSteps[stepCursor].byteCount(for: &value) ?? 0
                    stepForwardCurrentByteCount = 0
                }

                let bytesToForward = stepForwardTotalByteCount - stepForwardCurrentByteCount
                if bytesToForward > 0 {
                    let bytesForwarded = try forwardBytes(bytesToForward, forwarder, &value)

                    guard bytesForwarded <= bytesToForward else {
                        let error = DeserializationError.parsingFailed
                        storedFailure = error
                        throw error
                    }

                    stepForwardCurrentByteCount += bytesForwarded
                    if stepForwardCurrentByteCount < stepForwardTotalByteCount {
                        // Still need more bytes forwarded. Return and don't increment.
                        return nil
                    }
                }
            }

            if streamSteps[stepCursor].shouldFinalize {
                // Told to finalize, return complete value now and reset
                return extractValueAndReset()
            }

            // Completed this step, move onto the next
            stepCursor += 1
        }

        // At this point, all steps are completed, return the value (implicit finalize)
        return extractValueAndReset()
    }

    public mutating func handleInput(_ factory: inout Factory) throws(DeserializationError) -> T? {
        try handleInputInternal(
            { builder, value in
                Deserializer<Factory>.deserialize(&factory) { read throws(DeserializationError) in
                    try builder(&read, &value)
                }
            },
            { loopBuilder, value in
                var loopResult = StepLoopResult.breakLoop
                let result = Deserializer<Factory>.deserialize(&factory) { read throws(DeserializationError) in
                    loopResult = try loopBuilder(&read, &value)
                }
                return (result, loopResult)
            },
            { forwardByteCount, forwarder, value throws(DeserializationError) in
                // Forwarding not supported for generic span factory
                throw .parsingFailed
            }
        )
    }

    public static func parsePartialMessage(_ chunkBuilder: @escaping StepBuilder) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.parse(chunkBuilder))
    }

    public static func parsePartialMessage(
        if when: @escaping StepConditionEvaluator,
        _ chunkBuilder: @escaping StepBuilder
    ) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.parseWhen(when, chunkBuilder))
    }

    public static func parsePartialMessage(
        while _while: @escaping StepConditionEvaluator,
        upTo: StepByteCountEvaluator? = nil,
        _ chunkBuilder: @escaping StepLoopBuilder
    ) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(
            .parseWhile(_while, upTo, chunkBuilder)
        )
    }

    public static func forwardPartialMessage(
        byteCount: @escaping StepByteCountEvaluator,
        to forwarder: @escaping StepByteForwarder
    ) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.forward(byteCount, forwarder))
    }

    public static func finalizeMessage() -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.finalize)
    }

    public static func finalizeMessage(if when: @escaping StepConditionEvaluator) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.finalizeWhen(when))
    }
}

@available(Network 0.1.0, *)
extension StreamDeserializer
where T: StreamDeserializerState & ~Copyable, Factory: DeserializerSpanFactory & ~Copyable & ~Escapable {
    public static func beginState(_ stateIdentifier: StateIdentifier) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.beginState(stateIdentifier))
    }

    public static func jumpToState(
        _ stateIdentifier: StateIdentifier,
        if when: @escaping StepConditionEvaluator
    ) -> [Step] {
        StreamDeserializationBuilder<T, StateIdentifier, Factory>.buildExpression(.jumpToState(stateIdentifier, when))
    }
}

@available(Network 0.1.0, *)
extension StreamDeserializer where T: ~Copyable, Factory == FrameArraySpanFactory {
    public mutating func handleFrames(_ frames: inout FrameArray) throws(DeserializationError) -> T? {
        try handleInputInternal(
            { builder, value in
                Deserializer.deserialize(&frames, claim: true, removeClaimedFrames: true) {
                    read throws(DeserializationError) in
                    try builder(&read, &value)
                }
            },
            { loopBuilder, value in
                var loopResult = StepLoopResult.breakLoop
                let result = Deserializer.deserialize(&frames, claim: true, removeClaimedFrames: true) {
                    read throws(DeserializationError) in
                    loopResult = try loopBuilder(&read, &value)
                }
                return (result, loopResult)
            },
            { forwardByteCount, forwarder, value throws(DeserializationError) in
                var factory = FrameArraySpanFactory(consume frames)
                let bytesConsumed = forwarder(forwardByteCount, &factory, &value)
                frames = factory.takeFrameArray()
                return bytesConsumed
            }
        )
    }
}

@available(Network 0.1.0, *)
extension StreamDeserializer where T: ~Copyable, Factory == EmptySpanFactory {
    public mutating func handleSpan(_ span: RawSpan) throws(DeserializationError) -> T? {
        try handleInputInternal(
            { builder, value in
                Deserializer.deserialize(span) { read throws(DeserializationError) in
                    try builder(&read, &value)
                }
            },
            { loopBuilder, value in
                var loopResult = StepLoopResult.breakLoop
                let result = Deserializer.deserialize(span) { read throws(DeserializationError) in
                    loopResult = try loopBuilder(&read, &value)
                }
                return (result, loopResult)
            },
            { forwardByteCount, forwarder, value throws(DeserializationError) in
                // Forwarding not supported for single span factory
                throw .parsingFailed
            }
        )
    }
}

@available(Network 0.1.0, *)
extension StreamDeserializer where Factory: ~Copyable & ~Escapable, T: ~Copyable, StateIdentifier == Int {
    public static func parser(
        @StreamDeserializationBuilder<T, StateIdentifier, Factory> _ builder: (_ stream: StreamDeserializer.Type) ->
            Steps
    ) -> Steps {
        builder(StreamDeserializer.self)
    }

    public init(_ valueGenerator: @escaping ValueGenerator, parser: Steps) {
        self.init(valueGenerator, parser)
    }
}

@available(Network 0.1.0, *)
extension StreamDeserializer where Factory: ~Copyable & ~Escapable, T: StreamDeserializerState & ~Copyable {
    public static func parser(
        @StreamDeserializationBuilder<T, T.StateMachineStepIdentifier, Factory> _ builder: (
            _ stream: StreamDeserializer.Type
        ) -> Steps
    ) -> Steps {
        builder(StreamDeserializer.self)
    }

    public init(parser: Steps) {
        self.init({ T.init() }, parser)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias FrameArrayStreamDeserializer<T: StreamDeserializerState & ~Copyable> = StreamDeserializer<
    T, T.StateMachineStepIdentifier, FrameArraySpanFactory
>

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias SpanStreamDeserializer<T: StreamDeserializerState & ~Copyable> = StreamDeserializer<
    T, T.StateMachineStepIdentifier, EmptySpanFactory
>
