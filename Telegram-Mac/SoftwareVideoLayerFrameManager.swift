//
//  SoftwareVideoLayerFrameManager.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 26/05/2020.
//  Copyright © 2020 Telegram. All rights reserved.
//

import Cocoa
import Foundation
import TGUIKit
import Postbox
import TelegramCore
import SyncCore
import SwiftSignalKit
import CoreMedia


private let applyQueue = Queue()
private let workers = ThreadPool(threadCount: 3, threadPriority: 0.2)
private var nextWorker = 0

final class SoftwareVideoLayerFrameManager {
    private var dataDisposable = MetaDisposable()
    private let source = Atomic<SoftwareVideoSource?>(value: nil)
    
    private var baseTimestamp: Double?
    private var frames: [MediaTrackFrame] = []
    private var minPts: CMTime?
    private var maxPts: CMTime?
    
    private let account: Account
    private let resource: MediaResource
    private let secondaryResource: MediaResource?
    private let queue: ThreadPoolQueue
    private let layerHolder: SampleBufferLayer
    
    private var rotationAngle: CGFloat = 0.0
    private var aspect: CGFloat = 1.0
    
    private var layerRotationAngleAndAspect: (CGFloat, CGFloat)?
    
    init(account: Account, fileReference: FileMediaReference, layerHolder: SampleBufferLayer) {
        var resource = fileReference.media.resource
        var secondaryResource: MediaResource?
        for attribute in fileReference.media.attributes {
            if case .Video = attribute {
                if let thumbnail = fileReference.media.videoThumbnails.first {
                    resource = thumbnail.resource
                    secondaryResource = fileReference.media.resource
                }
            }
        }
        
        nextWorker += 1
        self.account = account
        self.resource = resource
        self.secondaryResource = secondaryResource
        self.queue = ThreadPoolQueue(threadPool: workers)
        self.layerHolder = layerHolder
        layerHolder.layer.videoGravity = .resizeAspectFill
        layerHolder.layer.masksToBounds = true
    }
    
    deinit {
        self.dataDisposable.dispose()
    }
    
    func start() {
        let secondarySignal: Signal<String?, NoError>
        if let secondaryResource = self.secondaryResource {
            secondarySignal = self.account.postbox.mediaBox.resourceData(secondaryResource, option: .complete(waitUntilFetchStatus: false))
                |> map { data -> String? in
                    if data.complete {
                        return data.path
                    } else {
                        return nil
                    }
            }
        } else {
            secondarySignal = .single(nil)
        }
        
        let firstReady: Signal<String, NoError> = combineLatest(
            self.account.postbox.mediaBox.resourceData(self.resource, option: .complete(waitUntilFetchStatus: false)) |> filter { $0.complete },
            secondarySignal
            )
            |> mapToSignal { first, second -> Signal<String, NoError> in
                if let second = second {
                    return .single(second)
                } else if first.complete {
                    return .single(first.path)
                } else {
                    return .complete()
                }
            }
        
        self.dataDisposable.set((firstReady |> deliverOn(applyQueue)).start(next: { [weak self] path in
            if let strongSelf = self {
                let _ = strongSelf.source.swap(SoftwareVideoSource(path: path))
            }
        }))
    }
    
    func tick(timestamp: Double) {
        applyQueue.async {
            if self.baseTimestamp == nil && !self.frames.isEmpty {
                self.baseTimestamp = timestamp
            }
            
            if let baseTimestamp = self.baseTimestamp {
                var index = 0
                var latestFrameIndex: Int?
                while index < self.frames.count {
                    if baseTimestamp + self.frames[index].position.seconds + self.frames[index].duration.seconds <= timestamp {
                        latestFrameIndex = index
                        //print("latestFrameIndex = \(index)")
                    }
                    index += 1
                }
                if let latestFrameIndex = latestFrameIndex {
                    let frame = self.frames[latestFrameIndex]
                    for i in (0 ... latestFrameIndex).reversed() {
                        self.frames.remove(at: i)
                    }
                    if self.layerHolder.layer.status == .failed {
                        self.layerHolder.layer.flush()
                    }
                    //if frame.resetDecoder {
//                        self.layerHolder.layer.flushAndRemoveImage()
                   // }
                    
                    
                    /*if self.layerRotationAngleAndAspect?.0 != self.rotationAngle || self.layerRotationAngleAndAspect?.1 != self.aspect {
                     self.layerRotationAngleAndAspect = (self.rotationAngle, self.aspect)
                     var transform = CGAffineTransform(rotationAngle: CGFloat(self.rotationAngle))
                     if !self.rotationAngle.isZero {
                     transform = transform.scaledBy(x: CGFloat(self.aspect), y: CGFloat(1.0 / self.aspect))
                     }
                     self.layerHolder.layer.setAffineTransform(transform)
                     }*/
                    self.layerHolder.layer.enqueue(frame.sampleBuffer)
                }
            }
            
            self.poll()
        }
    }
    
    private var polling = false
    
    private func poll() {
        if self.frames.count < 2 && !self.polling {
            self.polling = true
            let minPts = self.minPts
            let maxPts = self.maxPts
            self.queue.addTask(ThreadPoolTask { [weak self] state in
                if state.cancelled.with({ $0 }) {
                    return
                }
                if let strongSelf = self {
                    var frameAndLoop: (MediaTrackFrame?, CGFloat, CGFloat, Bool)?
                    
                    var hadLoop = false
                    for _ in 0 ..< 1 {
                        frameAndLoop = (strongSelf.source.with { $0 })?.readFrame(maxPts: maxPts)
                        if let frameAndLoop = frameAndLoop {
                            if frameAndLoop.0 != nil || minPts != nil {
                                break
                            } else {
                                if frameAndLoop.3 {
                                    hadLoop = true
                                }
                                //print("skip nil frame loop: \(frameAndLoop.3)")
                            }
                        } else {
                            break
                        }
                    }
                    if let loop = frameAndLoop?.3, loop {
                        hadLoop = true
                    }
                    
                    applyQueue.async {
                        if let strongSelf = self {
                            strongSelf.polling = false
                            if let (_, rotationAngle, aspect, _) = frameAndLoop {
                                strongSelf.rotationAngle = rotationAngle
                                strongSelf.aspect = aspect
                            }
                            if let frame = frameAndLoop?.0 {
                                if strongSelf.minPts == nil || CMTimeCompare(strongSelf.minPts!, frame.position) < 0 {
                                    var position = CMTimeAdd(frame.position, frame.duration)
                                    for _ in 0 ..< 1 {
                                        position = CMTimeAdd(position, frame.duration)
                                    }
                                    strongSelf.minPts = position
                                }
                                strongSelf.frames.append(frame)
                                strongSelf.frames.sort(by: { lhs, rhs in
                                    if CMTimeCompare(lhs.position, rhs.position) < 0 {
                                        return true
                                    } else {
                                        return false
                                    }
                                })
                                //print("add frame at \(CMTimeGetSeconds(frame.position))")
                                //let positions = strongSelf.frames.map { CMTimeGetSeconds($0.position) }
                                //print("frames: \(positions)")
                            } else {
                                //print("not adding frames")
                            }
                            if hadLoop {
                                strongSelf.maxPts = strongSelf.minPts
                                strongSelf.minPts = nil
                                //print("loop at \(strongSelf.minPts)")
                            }
                            strongSelf.poll()
                        }
                    }
                }
            })
        }
    }
}