//
//  LocalPeer.swift
//  Pods
//
//  Created by Julian Asamer on 04/07/14.
//
//

import Foundation

protocol RouterHandler: class {
    func didFindNode(router: Router, node: Node)
    func didImproveRoute(router: Router, node: Node)
    func didLoseNode(router: Router, node: Node)
    func handleConnection(router: Router, node: Node, connection: UnderlyingConnection)
}

var broadcastDelaySettings: (shortDelay: Double, regularDelay: Double) = (0.5, 5)

/**
* The Router class is responsible for discovering remote peers (represented via the Node class) in the network (both directly and indirectly reachable ones), 
* and establish connections to those peers.
*
* In this implementation, this involves the following tasks:
* 
* - Using of Reto Modules to discover direct neighbors and advertise the local peer (this is implemented in the DefaultRouter subclass).
* - Distribution of routing information using a flooding algorithm.
* - Building a link-state routing table based on that information.
* - Computing reachability information about other nodes when new routing information is received and informing the delegate about changes in reachabilty
* - Establishing connections to other peers, including routed connections
* - Acting as a router for other nodes, i.e. forwarding data from one peer to another, without handling the data on the local peer
* - Supporting multicast connections (computing routes, handling incoming underlying connections accordingly)
*/
class Router {
    /** The local peer's identifier */
    let identifier: UUID
    /** The dispatch queue used for networking related tasks. Delegate methods are also called on this queue. */
    let dispatchQueue: dispatch_queue_t
    /** The Router's delegate. */
    weak var delegate: RouterHandler?
    /** A map from a node's UUID to the node for all Nodes known to the Router */
    var nodes: [UUID: Node] = [:]
    /** The set of Nodes that are neighbors of the local peer. */
    var neighbors: Set<Node> = []
    /** The linkStatePacketManager floods LinkStatePackets (i.e. routing information) through the network */
    var linkStatePacketManager: FloodingPacketManager?
    /** Link state information packets are flooded periodically. The delayedLinkStateBroadcaster calls the appropriate methods in specified intervals. */
    var delayedLinkStateBroadcaster: RepeatedExecutor!
    /** The routing table that builds a representation of the network using received link state information. */
    let routingTable: LinkStateRoutingTable<UUID>
    /** 
    * Forking connections act as a normal underling connection for the local peer, but forward received data to another peer in the background. 
    * This type of connection is used in multicast connections.
    * As the local peer may not hold a reference to the connection, it must be retained here.
    */
    var forkingConnections: Set<ForkingConnection> = []
    /**
    * Stores connections for which the next hop connections have not been established yet to keep them from deallocating.
    */
    var connectionsAwaitingForwardedConnections: [UnderlyingConnection] = []
    /** 
    * Constructs a Router.
    * @param identifier The local peer's identifier
    * @param dispatchQueue The dispatch queue used for networking purposes. Delegate methods are also called on this queue.
    **/
    init(identifier: UUID, dispatchQueue: dispatch_queue_t) {
        self.identifier = identifier
        self.dispatchQueue = dispatchQueue
        self.routingTable = LinkStateRoutingTable(localNode: identifier)

        self.linkStatePacketManager = FloodingPacketManager(router: self)
        self.linkStatePacketManager?.addPacketHandler(
            PacketType.LinkState,
            handler: {
                [unowned self]
                data, type in
                if let packet = LinkStatePacket.deserialize(data) {
                    self.handleLinkStatePacket(packet)
                }
            }
        )
        self.delayedLinkStateBroadcaster = RepeatedExecutor(
            regularDelay: broadcastDelaySettings.regularDelay,
            shortDelay: broadcastDelaySettings.shortDelay,
            dispatchQueue: self.dispatchQueue
        )
        self.delayedLinkStateBroadcaster.start { [unowned self] in self.broadcastLinkStateInformation() }
    }
    /** Constructs a new node for a given identifier. */
    func provideNode(nodeIdentifier: UUID) -> Node {
        let node = self.nodes.getOrDefault(
            nodeIdentifier,
            defaultValue: Node(identifier: nodeIdentifier, localIdentifier: self.identifier, linkStatePacketManager: self.linkStatePacketManager)
        )
        node.router = self
        return node
    }
    /** 
    * Adds an address for a given node.
    * The routing metadata connection for that node is established.
    * Finally, changes in reachability are computed, and the delegate is informed about any changes.
    */
    func addAddress(nodeIdentifier: UUID, address: Address) {
        if nodeIdentifier == self.identifier { return }

        let node = self.provideNode(nodeIdentifier)
        node.addAddress(address)
        node.establishRoutingConnection()
        
        self.updateNodesWithRoutingTableChange(self.routingTable.getRoutingTableChangeForNeighborUpdate(nodeIdentifier, cost: Double(node.bestAddress?.cost ?? 1000)))
    }
    /** 
    * Removes an address for a node. 
    * Notifies the delegate about routing table changes.
    */
    func removeAddress(nodeIdentifier: UUID, address: Address) {
        if nodeIdentifier == self.identifier { return }
        
        let node = self.provideNode(nodeIdentifier)
        node.removeAddress(address)
        if let bestAddress = node.bestAddress {
            self.updateNodesWithRoutingTableChange(self.routingTable.getRoutingTableChangeForNeighborUpdate(nodeIdentifier, cost: Double(bestAddress.cost)))
        } else {
            self.updateNodesWithRoutingTableChange(self.routingTable.getRoutingTableChangeForNeighborRemoval(nodeIdentifier))
        }
    }
    
    // MARK: Establishing connections
    
    /*
    * Establishes a direct connection with a specific ConnectionPurpose to a given neighboring destination node
    *
    * @param destination The node to establish the connection with. Needs to be a direct neighbor of this node.
    * @param purpose The connection's purpose. Used to differentiate between routing metadata connections and standard routed connections.
    * @param onConnection A callback called when the connection is established.
    * @param onFail A closure called when an error occurs.
    */
    func establishDirectConnection(#destination: Node, purpose: ConnectionPurpose, onConnection: (UnderlyingConnection) -> (), onFail: () -> ()) {
        if let underlyingConnection = destination.bestAddress?.createConnection() {
            underlyingConnection.connect()
            
            writeSinglePacket(
                connection: underlyingConnection,
                packet: LinkHandshake(peerIdentifier: self.identifier, connectionPurpose: purpose),
                onSuccess: { onConnection(underlyingConnection) },
                onFail: {
                    log(.Medium, error: "Failed to establish direct connection.")
                    onFail()
                }
            )
        } else {
            log(.Medium, error: "Failed to establish direct connection as no direct addresses are known for this node.")
            onFail()
        }
    }
    /**
    * Handles direct connections. Expects to receive a LinkHandshake packet, which is sent by this method's counterpart, establishDirectConnection.
    * Depending on the ConnectionPurpose received, the connection is either used as a routing connection, or handled as a hop connection.
    */
    func handleDirectConnection(connection: UnderlyingConnection) {
        readSinglePacket(
            connection: connection,
            onPacket: {
                data in
                if let packet = LinkHandshake.deserialize(data) {
                    switch packet.connectionPurpose {
                        case .RoutingConnection: self.provideNode(packet.peerIdentifier).handleRoutingConnection(connection)
                        case .RoutedConnection: self.handleHopConnection(connection: connection)
                        default: break
                    }
                } else {
                    log(.Medium, error: "Did not receive LinkHandshake.")
                    connection.close()
                }
            },
            onFail: {
                log(.Medium, error: "received no or invalid data instead of peer handshake, closing connection.")
                connection.close()
            }
        )
    }
    
    /** 
    * Establishes all hop connections based on a nextHopTree. Hop connections are direct connections between two nodes and are part of a routed or multicast connection.
    * When establishing a routed connection, multiple peers may need to establish direct connections to each other. This method establishes the connections
    * that need to be established by the local peer.
    * 
    * This method establishes a direct connection for each child of the root (the local peer) of the next hop tree passed in. 
    * It then sends a MulticastHandshake over each connection. 
    *
    * If there are multiple children, a MulticastConnection is constructed that bundles the connections (i.e. it acts as a single connection that sends data to a set of subconnections).
    * If the local peer is a destination, a ForkingConnection used that is handled by the local peer as a normal underlying connection.
    *
    * @param destinationIdentifiers A set of UUIDs representing all destinations of the multicast connection for which the hop connections are used.
    * @param nextHopTree A Tree of UUIDs rooted at the local peer. This method establishes direct connections to each child, then sends the subtrees of the next hop tree to each child, such that they in turn can establish the next hop connections.
    * @param sourcePeerIdentifier The peer from which this connection originated.
    * @param onConnection A closure that is called when the next hop connections were established.
    * @param onFail A closure that is called when the connection establishement process failed.
    */
    func establishHopConnections(#destinationIdentifiers: Set<UUID>, nextHopTree: Tree<UUID>, sourcePeerIdentifier: UUID, onConnection: (UnderlyingConnection) -> (), onFail: () -> ()) {
        let multicastConnection: MulticastConnection? = (nextHopTree.subtrees.count > 1) ? MulticastConnection() : nil
        var establishmentFailed = false
        
        let onFailClosure: () -> () = {
            establishmentFailed = true
            multicastConnection?.close()
            onFail()
        }
        
        for nextHopSubtree in nextHopTree.subtrees {
            self.establishDirectConnection(
                destination: self.provideNode(nextHopSubtree.value),
                purpose: ConnectionPurpose.RoutedConnection,
                onConnection: {
                    connection in
                    let handshake = MulticastHandshake(sourcePeerIdentifier: sourcePeerIdentifier, destinationIdentifiers: destinationIdentifiers, nextHopTree: nextHopSubtree)
                    
                    writeSinglePacket(
                        connection: connection,
                        packet: handshake,
                        onSuccess: {
                            if establishmentFailed {
                                connection.close()
                                return
                            }
                            
                            if let multicastConnection = multicastConnection {
                                multicastConnection.addSubconnection(connection)
                                
                                if multicastConnection.subconnections.count == nextHopTree.subtrees.count {
                                    onConnection(multicastConnection)
                                }
                            } else {
                                onConnection(connection)
                            }
                        },
                        onFail: onFailClosure
                    )
                },
                onFail: onFailClosure
            )
        }
    }
    
    /** 
    * Handles a incoming hop connection (i.e. a direct connection with a purpose of RoutedConnection).
    * Expects to receive a MulticastHandshake from the connection. 
    * 
    * If the next hop tree in the MulticastHandshake is a leaf, the connection can be handled as a multicast connection directly.
    * Otherwise, the nextHopTree is used to establish the next hop connections, to which data is forwarded. 
    * The connection is only handled on the local peer if it is a destination.
    *
    * @param connection The connection to handle
    */
    func handleHopConnection(#connection: UnderlyingConnection) {
        readSinglePacket(
            connection: connection,
            onPacket: {
                if let multicastHandshake = MulticastHandshake.deserialize($0) {
                    if multicastHandshake.nextHopTree.isLeaf {
                        self.handleMulticastConnection(sourcePeerIdentifier: multicastHandshake.sourcePeerIdentifier, connection: connection)
                    } else {
                        self.establishForwardingConnections(
                            sourcePeerIdentifier: multicastHandshake.sourcePeerIdentifier,
                            destinations: multicastHandshake.destinationIdentifiers,
                            nextHopTree: multicastHandshake.nextHopTree,
                            incomingConnection: connection
                        )
                    }
                } else {
                    log(.Medium, error: "Received invalid MulticastHandshake.")
                    connection.close()
                }
            },
            onFail: {
                log(.Medium, error: "Failed to read multicast handshake when handling hop connection.")
            }
        )
    }
    /**
    * Establishes forwarding connections. Data received from an incoming connection is forwarded to an outgoing connection established via establishHopConnections,
    * and vice versa. If the local peer is a destination, a ForkingConnection is used to allow the local peer to handle the connection.
    * 
    * @param sourcePeerIdentifier The UUID of the peer which originally established the connection.
    * @param destinations A set of UUIDs that represent the destinations.
    * @param nextHopTree A tree rooted at the local peer representing the connections that still need to be established.
    * @param incomingConnection The connection from which data should be forwarded.
    */
    func establishForwardingConnections(#sourcePeerIdentifier: UUID, destinations: Set<UUID>, nextHopTree: Tree<UUID>, incomingConnection: UnderlyingConnection) {
        self.connectionsAwaitingForwardedConnections.append(incomingConnection)
        
        self.establishHopConnections(destinationIdentifiers: destinations, nextHopTree: nextHopTree, sourcePeerIdentifier: sourcePeerIdentifier,
            onConnection: {
                outgoingConnection in
                let connection = self.createForkingConnection(incomingConnection, outgoingConnection)
                if destinations.contains(self.identifier) {
                    self.handleMulticastConnection(sourcePeerIdentifier: sourcePeerIdentifier, connection: connection)
                }
                
                self.connectionsAwaitingForwardedConnections = self.connectionsAwaitingForwardedConnections.filter { $0 === incomingConnection }
            }, onFail: {
                log(.Medium, error: "Failed to establish forwarding connections.")
                incomingConnection.close()
                self.connectionsAwaitingForwardedConnections = self.connectionsAwaitingForwardedConnections.filter { $0 === incomingConnection }
            }
        )
    }
    /** Creates a forking connection for an incoming and outgoing connection. */
    func createForkingConnection(incomingConnection: UnderlyingConnection, _ outgoingConnection: UnderlyingConnection) -> UnderlyingConnection {
        let forkingConnection = ForkingConnection(
            incomingConnection: incomingConnection,
            outgoingConnection: outgoingConnection,
            onClose: self.removeForkingConnection
        )
        self.forkingConnections += forkingConnection
        
        return forkingConnection
    }
    /** Removes a forking connection. */
    func removeForkingConnection(forkingConnection: ForkingConnection) {
        log(.Low, info: "Forwarding connection closed.")
        
        self.forkingConnections -= forkingConnection
    }
    
    /** 
    * Establishes a multicast connection to a set of destinations. If the destinations set contains only one element, a unicast connection is established.
    *
    * Starts the hop connection establishement process. Expects a confirmation packet from all destinations to ensure that the connection was established successfully (these packets are sent by the handleMulticastConnection method). Finally sends a confirmation packet in turn, to signal that the connection is fully functional.
    *
    * @param destinations A set of destinations.
    * @param onConnection A closure that is called when the connection was fully established.
    * @param onFail A closure that is called when the connection establishment process fails.
    */
    func establishMulticastConnection(#destinations: Set<Node>, onConnection: (UnderlyingConnection) -> (), onFail: () -> ()) {
        let destinationIdentifiers = destinations.map { $0.identifier }
        let nextHopTree = self.routingTable.getHopTree(destinationIdentifiers)
        var receivedConfirmations: Set<UUID> = []
        
        self.establishHopConnections(
            destinationIdentifiers: destinationIdentifiers,
            nextHopTree: nextHopTree,
            sourcePeerIdentifier: self.identifier,
            onConnection: {
                connection in
                
                readPackets(
                    connection: connection,
                    packetCount: destinations.count,
                    onPacket: {
                        if let packet = RoutedConnectionEstablishedConfirmationPacket.deserialize($0) {
                            receivedConfirmations += packet.source
                        } else {
                            log(.Medium, error: "failed to receive confirmation packet.")
                            connection.close()
                        }
                    },
                    onSuccess: {
                        writeSinglePacket(
                            connection: connection,
                            packet: RoutedConnectionEstablishedConfirmationPacket(source: self.identifier),
                            onSuccess: {
                                onConnection(connection)
                            },
                            onFail: onFail
                        )
                    },
                    onFail: {
                        log(.Medium, error: "Did not receive all confirmation packets.")
                        onFail()
                    }
                )
            },
            onFail: {
                log(.Medium, error: "Failed to establish hop connections.")
                onFail()
            }
        )
    }
    /** 
    * Handles a multicast connection.
    * 
    * Sends a confirmation packet to the establisher of the connection. Then expects to receive a confirmation packet in turn.
    * Once the confirmation is received, the connection can be handled by the local peer.
    *
    * @param sourcepeerIdentifier The identifier of the peer that originally established the connection.
    * @param connection An underlying connection that should be handled.
    */
    func handleMulticastConnection(#sourcePeerIdentifier: UUID, connection: UnderlyingConnection) {
        writeSinglePacket(
            connection: connection,
            packet: RoutedConnectionEstablishedConfirmationPacket(source: self.identifier),
            onSuccess: {
                readSinglePacket(
                    connection: connection,
                    onPacket: {
                        if let packet = RoutedConnectionEstablishedConfirmationPacket.deserialize($0) {
                            self.delegate?.handleConnection(self, node: self.provideNode(sourcePeerIdentifier), connection: connection)
                        }
                    },
                    onFail: {
                        log(.Medium, error: "did not receive establishment information.")
                    }
                )
            },
            onFail: {
                log(.Medium, error: "Failed to send routed connection establishment confirmation.")
            }
        )
    }
    
    // MARK: Routing table related functionality
    
    /**
    * Updates all nodes with routing table changes.
    * Informs the delegate about any changes in reachability.
    * @param change A RoutingTableChange object reflecting a set of changes in the routing table.
    */
    func updateNodesWithRoutingTableChange(change: RoutingTableChange<UUID>) {
        if change.isEmpty { return }
        
        println()
        log(.Low, info: " -- Peer Discovery Information -- ")
        if change.nowReachable.isEmpty { println(" - No new nodes reachable.") }
        else { log(.Low, info: " - Peers now reachable: ") }
        
        for (discovered, nextHop, cost) in change.nowReachable {
            let discoveredNode = self.provideNode(discovered)
            let nextHopNode = self.provideNode(nextHop)
            
            discoveredNode.reachableVia = (nextHop: nextHopNode, cost: Int(cost))
            
            println("Reto[Info]: \t\(discovered) (via \(nextHop), cost: \(cost))")
            self.delegate?.didFindNode(self, node: discoveredNode)
        }
        
        if change.nowUnreachable.isEmpty { log(.Low, info: " - No nodes became unreachable.") }
        else { log(.Low, info: "Reto[Info]:  - Peers now unreachable: ") }
        
        for unreachable in change.nowUnreachable {
            let unreachableNode = self.provideNode(unreachable)
            
            unreachableNode.reachableVia = nil
            
            log(.Low, info: "Reto[Info]: \t\(unreachable))")
            self.delegate?.didLoseNode(self, node: unreachableNode)
        }
        
        if change.routeChanged.isEmpty { println("Reto[Info]:  - No routes changed.") }
        else { log(.Low, info: "Reto[Info]:  - Peers with changed routes: ") }
        
        for (changedNodeId, nextHop, oldCost, newCost) in change.routeChanged {
            let changedNode = self.provideNode(changedNodeId)
            
            if oldCost > newCost {
                self.delegate?.didImproveRoute(self, node: changedNode)
            }
            
            changedNode.reachableVia = (nextHop: self.provideNode(nextHop), cost: Int(newCost))
            
            log(.Low, info: "\t\(changedNodeId) (old cost: \(oldCost), new cost: \(newCost), reachable via: \(nextHop)")
        }
        
        println()
    }
    /**
    * Handles a received link state packet and updates the routing table.
    */
    func handleLinkStatePacket(packet: LinkStatePacket) {
        let change = self.routingTable.getRoutingTableChangeForLinkStateInformationUpdate(packet.peerIdentifier, neighbors: packet.neighbors.map({
            identifier, cost in
            (node: identifier, cost: Double(cost))
        }))
        
        self.updateNodesWithRoutingTableChange(change)
    }
    /** Broadcasts link state information using the linkStatePacketManager. */
    func broadcastLinkStateInformation() {
        let linkStateInformation = self.routingTable.linkStateInformation()
        let packet = LinkStatePacket(
            peerIdentifier: self.identifier,
            neighbors: linkStateInformation.map({ (identifier, cost) in (identifier: identifier, cost: Int32(cost)) }))
        
        self.linkStatePacketManager?.floodPacket(packet)
    }
    
    // MARK: Neighbor management
    /** Called by a Node when it became directly reachable. */
    func onNeighborReachable(node: Node) {
        log(.Low, info: " -- Discovered Neighbor: \(node.identifier) -- ")
        
        self.neighbors += node
        
        let change = self.routingTable.getRoutingTableChangeForNeighborUpdate(node.identifier, cost: Double(node.bestAddress?.cost ?? 1000))
        self.updateNodesWithRoutingTableChange(change)
        
        self.delayedLinkStateBroadcaster?.runActionInShortDelay()
    }
    /** Called by a Node when it lost its neighbor status. */
    func onNeighborLost(node: Node) {
        log(.Low, info: " -- Lost Neighbor: \(node.identifier) -- ")
        
        self.neighbors -= node
        let change = self.routingTable.getRoutingTableChangeForNeighborRemoval(node.identifier)
        
        self.updateNodesWithRoutingTableChange(change)
        
        self.delayedLinkStateBroadcaster?.runActionInShortDelay()
    }

}