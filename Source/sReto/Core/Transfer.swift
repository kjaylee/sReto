//
//  Transfer.swift
//  sReto
//
//  Created by Julian Asamer on 14/07/14.
//  Copyright (c) 2014 LS1 TUM. All rights reserved.
//

import Foundation

/**
* A Transfer object represents a data transfer between two or more peers. 
* It has two subclasses, InTransfer and OutTransfer, which represent an incoming transfer (i.e. a data transfer that is being received) and an outgoing transfer (i.e. a data transfer that is being sent to some other peer).
* OutTransfers are created by calling one of the send methods on the Connection class.
* InTransfers are created by the Connection class when the connected peer starts a data transfer. At this point, the connection's onTransfer event is invoked. Thus, InTransfers can be obtained by using the onTransfer event exposed by the Connection class.
*/
public class Transfer {
    // MARK: Events
    
    // Called when the transfer starts. If this property is set when the transfer is already started, the closure is called immediately.
    public var onStart: ((Transfer)->())? = nil {
        didSet { if isStarted { onStart?(self) } }
    }
    // Called whenever the transfer makes progress.
    public var onProgress: ((Transfer)->())? = nil
    // Called when the transfer completes successfully. To receive the data from an incoming transfer, use onCompleteData or onPartialData of InTransfer.
    public var onComplete: ((Transfer)->())? = nil {
        didSet { if isCompleted { onComplete?(self) } }
    }
    // Called when the transfer is cancelled.
    public var onCancel: ((Transfer)->())? = nil {
        didSet { if isCancelled { onEnd?(self) } }
    }
    // Called when the transfer ends, either by cancellation or completion.
    public var onEnd: ((Transfer)->())? = nil {
        didSet { if isCompleted || isCancelled { onEnd?(self) } }
    }
    
    // MARK: Properties
    /** The transfer's length in bytes*/
    public let length: Int
    /** Whether the transfer was been started */
    public internal(set) var isStarted: Bool = false
    /** Whether the transfer was completed successfully */
    public internal(set) var isCompleted: Bool = false
    /** Whether the transfer was cancelled */
    public internal(set) var isCancelled: Bool = false
    /** Indicates if the transfer is currently interrupted. This occurs, for example, when a connection closes unexpectedly. The transfer is resumed automatically on reconnect. */
    public internal(set) var isInterrupted: Bool = false
    /** The transfer's current progress in bytes */
    public internal(set) var progress: Int = 0
    /** Whether all data was sent. */
    public var isAllDataTransmitted: Bool { get { return self.progress == self.length } }
    
    /** 
    * Cancels the transfer. If the transfer is an incoming transfer, calling this method requests the cancellation from the sender.
    * This may take a little time. It is therefore possible that additional data is received, or even that the transfer completes before the cancel request reaches the sender. 
    * When the transfer is cancelled successfully, the onCancel event is called. You should use this event to determine whether the transfer is actually cancelled, and not assume that it's cancelled after calling the cancel method.
    */
    public func cancel() {}
    
    // MARK: Internal
    
    /** The transfer's identifier */
    internal let identifier: UUID
    /** The transfer's manager. */
    internal weak var manager: TransferManager?

    /** 
    * Constructs a Transfer.
    * @param manager The TransferManager responsible for this transfer.
    * @param length The total length of the transfer in bytes.
    * @param identifier The transfer's identifier.
    */
    internal init(manager: TransferManager, length: Int, identifier: UUID) {
        self.manager = manager
        self.length = length
        self.identifier = identifier
    }
    
    /** Updates the transfer's progress. */
    internal func updateProgress(numberOfBytes: Int) {
        assert(self.length >= self.progress+numberOfBytes, "Can not update the transfer's progress beyond its length.")
        
        self.progress += numberOfBytes
    }
    
    /** Call to change the transfer's state to started and dispatch the associated events. */
    internal func confirmStart() {
        self.isStarted = true
        self.onStart?(self)
    }
    /** Call to confirm updated progress and dispatch the associated events. */
    internal func confirmProgress() {
        self.onProgress?(self)
    }
    /** Call to change thet transfer's state to cancelled and dispatch the associated events. */
    internal func confirmCancel() {
        self.isCancelled = true
        self.onCancel?(self)
        self.confirmEnd()
    }
    /** Call to change thet transfer's state to completed and dispatch the associated events. */
    internal func confirmCompletion() {
        self.isCompleted = true
        self.onComplete?(self)
        self.confirmEnd()
    }
    /** Call to change thet transfer's state to ended, dispatch the associated events, and clean up events. */
    internal func confirmEnd() {
        self.onEnd?(self)
        
        self.onStart = nil
        self.onProgress = nil
        self.onComplete = nil
        self.onCancel = nil
        self.onEnd = nil
    }
}