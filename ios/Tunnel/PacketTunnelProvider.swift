import NetworkExtension

/// The VPN module only exists to keep the proxy running while Telegram is in
/// front: it routes a single unused address, so the phone's traffic is
/// untouched, and serves the MTProto proxy on 127.0.0.1.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var server: ProxyServer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let settings = ProxySettings.decode(proto?.providerConfiguration?[ProxySettings.providerKey] as? Data)
            ?? ProxySettings()

        let net = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: ["10.255.77.1"], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.77.2", subnetMask: "255.255.255.255")]
        net.ipv4Settings = v4
        net.mtu = 1500

        setTunnelNetworkSettings(net) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            let server = ProxyServer(settings: settings)
            do {
                try server.start()
            } catch {
                plog.error("Failed to start proxy: \(error)")
                completionHandler(error)
                return
            }
            self.server = server
            self.drainPackets()
            completionHandler(nil)
        }
    }

    /// Nothing is routed here except the dummy address; read and drop.
    private func drainPackets() {
        packetFlow.readPackets { [weak self] _, _ in
            self?.drainPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        plog.info("Stopping (reason \(reason.rawValue))")
        server?.stop()
        server = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let msg = ProviderMessage(rawValue: String(decoding: messageData, as: UTF8.self)) else {
            completionHandler?(nil)
            return
        }
        switch msg {
        case .status:
            completionHandler?(try? JSONEncoder().encode(stats.snapshot()))
        case .log:
            completionHandler?(Data(plog.text().utf8))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() {}
}
