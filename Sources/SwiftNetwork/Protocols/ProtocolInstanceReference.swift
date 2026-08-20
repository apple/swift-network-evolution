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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct ProtocolInstanceReference: Hashable {
    enum _ProtocolInstanceReference {
        case none
        case udp(_ instance: NetworkStateIndex)
        case ip(_ instance: NetworkStateIndex)
        case tcp(_ instance: TCPProtocol.Instance)
        case tls(_ instance: SwiftTLSProtocol.Instance)
        case streamEndpointFlow(_ instance: StreamEndpointFlowProtocol)
        case datagramEndpointFlow(_ instance: DatagramEndpointFlowProtocol)

        case tlsEncryptionLevel(_ instance: SwiftTLSProtocol.SwiftTLSQUICOnlyInstance.EncryptionLevelHandler)
        #if !NETWORK_NO_SWIFT_QUIC
        case quic(_ instance: QUICProtocol.Instance)
        case quicStream(_ instance: QUICStreamInstance)
        case quicDatagram(_ instance: QUICDatagramFlow)
        case quicPath(_ instance: QUICPath)
        case quicCrypto(_ instance: QUICCrypto)
        #endif
        #if !NETWORK_NO_TESTING_HARNESS
        case streamUpperHarness(_ instance: StreamUpperHarness)
        case datagramUpperHarness(_ instance: DatagramUpperHarness)
        case datagramLowerHarness(_ instance: DatagramLowerHarness)
        case streamLowerHarness(_ instance: StreamLowerHarness)
        case newStreamFlowHarness(_ instance: NewStreamFlowHarness)
        case newDatagramFlowHarness(_ instance: NewDatagramFlowHarness)
        #endif
        #if !NETWORK_EMBEDDED
        case custom(container: any ProtocolInstanceContainer, index: Int?)
        #endif
    }

    public static func == (lhs: ProtocolInstanceReference, rhs: ProtocolInstanceReference) -> Bool {
        (lhs._protocolEventStateIndex == rhs._protocolEventStateIndex
            && lhs._parentProtocolEventStateIndex == rhs._parentProtocolEventStateIndex)
    }

    public func hash(into hasher: inout Hasher) {
        if let _protocolEventStateIndex {
            hasher.combine(_protocolEventStateIndex)
        }
        if let _parentProtocolEventStateIndex {
            hasher.combine(_parentProtocolEventStateIndex)
        }
    }

    let reference: _ProtocolInstanceReference
    var context: NetworkContext

    let _protocolEventStateIndex: NetworkStateIndex?

    func protocolEventStateIndex(allowParent: Bool = true) -> NetworkStateIndex? {
        if let _parentProtocolEventStateIndex { return _parentProtocolEventStateIndex }
        return _protocolEventStateIndex
    }

    var _parentReference: _ProtocolInstanceReference?
    var _parentProtocolEventStateIndex: NetworkStateIndex?

    var parentReference: ProtocolInstanceReference? {
        get {
            guard let _parentReference else { return nil }
            return ProtocolInstanceReference(_parentReference, context, _parentProtocolEventStateIndex)
        }
        set {
            _parentReference = newValue?.reference
            _parentProtocolEventStateIndex = newValue?._protocolEventStateIndex
        }
    }

    private init(
        _ reference: _ProtocolInstanceReference,
        _ context: NetworkContext,
        _ protocolEventStateIndex: NetworkStateIndex?
    ) {
        self.reference = reference
        self.context = context
        self._protocolEventStateIndex = protocolEventStateIndex
    }

    public init() {
        self.reference = .none
        self.context = NetworkContext.implicitContext
        self._protocolEventStateIndex = nil
    }

    init(tcp instance: TCPProtocol.Instance) {
        self.reference = .tcp(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: context)
    }

    init(udp instance: inout UDPProtocol.Instance) {
        guard let index = instance.udpInstanceIndex else {
            self = .init()
            return
        }
        self.reference = .udp(index)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(ip instance: inout IPProtocol.Instance) {
        guard let index = instance.ipInstanceIndex else {
            self = .init()
            return
        }
        self.reference = .ip(index)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(tls instance: SwiftTLSProtocol.Instance) {
        self.reference = .tls(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(tlsEncryptionLevel instance: SwiftTLSProtocol.SwiftTLSQUICOnlyInstance.EncryptionLevelHandler) {
        self.reference = .tlsEncryptionLevel(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(streamEndpointFlow instance: StreamEndpointFlowProtocol) {
        self.reference = .streamEndpointFlow(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(datagramEndpointFlow instance: DatagramEndpointFlowProtocol) {
        self.reference = .datagramEndpointFlow(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    #if !NETWORK_NO_SWIFT_QUIC
    init(quic instance: QUICProtocol.Instance) {
        self.reference = .quic(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(quicStream instance: QUICStreamInstance) {
        self.reference = .quicStream(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(quicDatagram instance: QUICDatagramFlow) {
        self.reference = .quicDatagram(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(quicPath instance: QUICPath) {
        self.reference = .quicPath(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(quicCrypto instance: QUICCrypto) {
        self.reference = .quicCrypto(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }
    #endif

    #if !NETWORK_NO_TESTING_HARNESS
    init(streamUpperHarness instance: StreamUpperHarness) {
        self.reference = .streamUpperHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(datagramUpperHarness instance: DatagramUpperHarness) {
        self.reference = .datagramUpperHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(datagramLowerHarness instance: DatagramLowerHarness) {
        self.reference = .datagramLowerHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(streamLowerHarness instance: StreamLowerHarness) {
        self.reference = .streamLowerHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(newStreamFlowHarness instance: NewStreamFlowHarness) {
        self.reference = .newStreamFlowHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }

    init(newDatagramFlowHarness instance: NewDatagramFlowHarness) {
        self.reference = .newDatagramFlowHarness(instance)
        self.context = instance.context
        self._protocolEventStateIndex = instance.eventManager.register(with: self.context)
    }
    #endif

    #if !NETWORK_EMBEDDED
    public init(custom container: any ProtocolInstanceContainer, index: Int? = nil) {
        self.reference = .custom(container: container, index: index)
        var context = NetworkContext.implicitContext
        var eventStateIndex: NetworkStateIndex? = nil
        container.accessInstance(at: index) { instance in
            context = instance.context
            eventStateIndex = instance.eventManager.register(with: instance.context)
        }
        self.context = context
        self._protocolEventStateIndex = eventStateIndex
    }
    #else
    public init(custom: AnyObject, index: Int? = nil) {
        self.reference = .none
        self.context = NetworkContext.implicitContext
        self._protocolEventStateIndex = nil
    }
    #endif

    var isNone: Bool {
        switch self.reference {
        case .none: return true
        default: return false
        }
    }
}
