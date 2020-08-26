import Foundation
import NIO
import OSLog

protocol HandlerDelegate: AnyObject {
    func didReceive(packet: MQTTRecvPacket)
}

class Handler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var clientID: String
    var cleanSession: Bool
    var keepAlive: UInt16

    weak var delegate: HandlerDelegate?

    init(
        clientID: String,
        cleanSession: Bool,
        keepAlive: UInt16
    ) {
        self.clientID = clientID
        self.cleanSession = cleanSession
        self.keepAlive = keepAlive
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            let data = Data(bytes)
            do {
                let packet = try decode(data: data)
                delegate?.didReceive(packet: packet)
            } catch {
                print("error \(error)")
            }
        }
    }
}

public enum ConnectionState {
    case disconnected
    case connecting
    case connected
}

public protocol MQTTClientDelegate: AnyObject {
    var delegateDispatchQueue: DispatchQueue { get }

    func mqttClient(_ client: MQTTClient, didReceive packet: MQTTRecvPacket)
    func mqttClient(_ client: MQTTClient, didChange state: ConnectionState)
}

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
    case createNew
}

public class MQTTClient {
    public var host: String
    public var port: Int
    public var clientID: String
    public var cleanSession: Bool
    public var keepAlive: UInt16
    public var username: String?
    public var password: String?

    public weak var delegate: MQTTClientDelegate?

    private let group: EventLoopGroup

    private enum State {
        case disconnected
        case connecting(Channel)
        case connected(Channel)
    }

    private var state: State = .disconnected {
        didSet {
            delegate?.delegateDispatchQueue.async {
                switch self.state {
                case .disconnected:
                    self.invalidatePingTimer()
                    self.delegate?.mqttClient(self, didChange: .disconnected)
                case .connecting:
                    self.delegate?.mqttClient(self, didChange: .connecting)
                case .connected:
                    self.startPingTimer()
                    self.delegate?.mqttClient(self, didChange: .connected)
                }
            }
        }
    }

    private var _packetIdentifier: UInt16 = 0

    private let lockQueue = DispatchQueue(label: "packet identifier")

    private func nextPacketIdentifier() -> UInt16 {
        lockQueue.sync {
            if _packetIdentifier == 0xFFFF {
                _packetIdentifier = 0
            }
            _packetIdentifier += 1
            return _packetIdentifier
        }
    }

    public init(
        host: String,
        port: Int,
        loopGroupProvider: EventLoopGroupProvider = .createNew,
        clientID: String = "",
        cleanSession: Bool,
        keepAlive: UInt16,
        username: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        switch loopGroupProvider {
        case .createNew:
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        case let .shared(group):
            self.group = group
        }
        self.clientID = clientID
        self.cleanSession = cleanSession
        self.keepAlive = keepAlive
        self.username = username
        self.password = password
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    private func connectSocket() -> EventLoopFuture<Channel> {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = Handler(clientID: self.clientID,
                                      cleanSession: self.cleanSession,
                                      keepAlive: self.keepAlive)
                handler.delegate = self
                return channel.pipeline.addHandler(handler)
            }
        return bootstrap.connect(host: host, port: port)
    }

    @discardableResult
    public func connect() -> EventLoopFuture<Void>? {
        if isConnected {
            return nil
        }
        return connectSocket()
            .flatMap { channel in
                self.state = .connecting(channel)
                let packet = Connect(clientID: self.clientID,
                                     cleanSession: self.cleanSession,
                                     will: nil,
                                     username: self.username,
                                     password: self.password,
                                     keepAliveSec: self.keepAlive)
                return self.writeAndFlush(channel: channel, packet: packet)
            }
    }

    public var isConnected: Bool {
        switch state {
        case let .connected(channel):
            return channel.isActive
        default:
            return false
        }
    }

    private var keepAliveTimer: DispatchSourceTimer?

    private func startPingTimer() {
        keepAliveTimer?.cancel()
        keepAliveTimer = DispatchSource.makeTimerSource()
        keepAliveTimer?.schedule(deadline: .now() + Double(keepAlive), repeating: Double(keepAlive))
        keepAliveTimer?.setEventHandler(handler: { [weak self] in
            _ = self?.tryWrite(packet: PingReq())
        })
        keepAliveTimer?.resume()
    }

    private func invalidatePingTimer() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    // write packet or disconnect
    private func tryWrite<Packet: MQTTSendPacket>(packet: Packet) -> EventLoopFuture<Void>? {
        switch state {
        case let .connected(channel):
            return writeAndFlush(channel: channel, packet: packet)
        case .connecting:
            os_log("Client is still trying to connect", log: .default, type: .info)
            return nil
        default:
            return nil
        }
    }

    private func writeAndFlush<Packet: MQTTSendPacket>(channel: Channel, packet: Packet) -> EventLoopFuture<Void> {
        let bytes = packet.encode()
        print([UInt8](bytes))
        return channel.writeAndFlush(ByteBuffer(bytes: bytes))
            .always {
                if case let .failure(error) = $0 {
                    os_log("Write Error: %@", log: .default, type: .error, String(describing: error))
//                    self.state = .disconnected
                }
            }
    }

    @discardableResult
    public func disconnect() -> EventLoopFuture<Void>? {
        switch state {
        case let .connecting(channel):
            return channel
                .close()
                .always { _ in self.state = .disconnected }
        case let .connected(channel):
            return writeAndFlush(channel: channel, packet: Disconnect())
                .flatMap { channel.close() }
                .always { _ in self.state = .disconnected }
        case .disconnected:
            return nil
        }
    }

    public func publish(topic: String, identifier: UInt16? = nil, retain: Bool, qos: QoS, payload: DataEncodable) -> EventLoopFuture<Void>? {
        let packet = Publish(topic: topic, identifier: identifier ?? nextPacketIdentifier(), retain: retain, qos: qos, payload: payload.encode())
        return tryWrite(packet: packet)
    }

    public func subscribe(topic: String, qos: QoS, identifier: UInt16? = nil) -> EventLoopFuture<Void>? {
        self.subscribe(topicFilter: Subscribe.TopicFilter(topic: topic, qos: qos), identifier: identifier)
    }
    
    public func subscribe(topicFilter: Subscribe.TopicFilter, identifier: UInt16? = nil) -> EventLoopFuture<Void>? {
        return self.subscribe(topicFilters: [topicFilter])
    }
    
    public func subscribe(topicFilters: [Subscribe.TopicFilter], identifier: UInt16? = nil) -> EventLoopFuture<Void>? {
        let packet = Subscribe(identifier: identifier ?? nextPacketIdentifier(),
                               topicFilters: topicFilters)
        return tryWrite(packet: packet)
    }

    public func unsubscribe(topic: String, identifier: UInt16? = nil) -> EventLoopFuture<Void>? {
        let packet = Unsubscribe(identifier: identifier ?? nextPacketIdentifier(), topicFilters: [topic])
        return tryWrite(packet: packet)
    }
}

extension MQTTClient: HandlerDelegate {
    func didReceive(packet: MQTTRecvPacket) {
        switch packet {
        case let packet as ConnAck:
            if case let .connecting(channel) = state, packet.returnCode == .accepted {
                self.state = .connected(channel)
            } else {
                state = .disconnected
            }
//        case let packet as Publish:
//            if let channel = channel {
//                switch packet.qos {
//                case .atLeastOnce:
//                    let identifier = packet.variableHeader.identifier
//        //                    writeAndFlush(channel: channel, packet: PubAck(identifier: identifier))
//                case .exactlyOnce:
//                    let identifier = packet.variableHeader.identifier
//                default:
//                    break
//                }
//            }
        case let packet as PubRec:
            let identifier = packet.variableHeader.identifier
            tryWrite(packet: PubRel(identifier: identifier))
        default:
            break
        }
        delegate?.delegateDispatchQueue.async {
            self.delegate?.mqttClient(self, didReceive: packet)
        }
    }
}
