//
//  AirstreamManager.swift
//  AirAP
//
//  Created by neon443 on 16/05/2025.
//

import Foundation
import Airstream
import AVFoundation
import UIKit
import SwiftUI
import MediaPlayer

class AirstreamManager: NSObject, ObservableObject, AirstreamDelegate {
	@Published var airstream: Airstream?
	@Published var settings: AAPSettingsModel

	var audioUnit: AudioComponentInstance?
	var circularBuffer = TPCircularBuffer()
	var buffering: Bool = false

	private let userdefaults = UserDefaults(suiteName: "group.neon443.AirAP") ?? UserDefaults.standard

	@Published var running = false
	@Published var canControl = false

	/// Minimum amount of audio (in bytes) that must be present in the circular buffer before we
	/// allow CoreAudio to start rendering.
	private var minBufferBytes: Int32 = 176_000
	private let targetLatencySeconds: Double = 1.0

	@Published var title: String?
	@Published var album: String?
	@Published var artist: String?
	@Published var albumArt: UIImage?

	// MARK: - Steering wheel / remote commands
	private var remoteCommandsInstalled: Bool = false

	override init() {
		self.settings = AAPSettingsModel()
		super.init()

		// Allocate a generous 1 MiB circular buffer.
		_TPCircularBufferInit(&circularBuffer, 1_048_576, MemoryLayout.size(ofValue: circularBuffer))

		// IMPORTANT: Install remote command handlers ALWAYS (prevents fallback to local Music).
		installRemoteCommandsIfNeeded()

		//	#if RELEASE
		start()
		//	#endif
	}

	deinit {
		// Keep the system clean
		uninstallRemoteCommands()

		TPCircularBufferClear(&circularBuffer)

		if let audioUnit = audioUnit {
			let status = AudioOutputUnitStop(audioUnit)
			if status != noErr {
				print("failed to stop audio unit")
			}
		}
		audioUnit = nil
	}

	// MARK: - Public controls

	func start() {
		airstream = Airstream(name: settings.name)
		airstream?.delegate = self
		airstream?.startServer()

		withAnimation {
			running = true
		}

		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
		try? AVAudioSession.sharedInstance().setActive(true)

		// Claim Now Playing so iOS routes remote commands here (not to local Music).
		updateNowPlaying(active: true)
	}

	func stop() {
		airstream?.stopServer()

		withAnimation {
			running = false
			canControl = false
			clearMetadata()
		}

		// Keep remote commands installed even when stopped (prevents fallback to Music).
		updateNowPlaying(active: false)
	}

	func startStop() {
		switch running {
		case true: stop()
		case false: start()
		}
	}

	func clearMetadata() {
		albumArt = nil
		title = nil
		album = nil
		artist = nil
	}

	// MARK: - Now Playing (helps routing remote controls)

	private func updateNowPlaying(active: Bool) {
		var info: [String: Any] = [
			MPMediaItemPropertyTitle: "AirAP Receiver",
			MPMediaItemPropertyArtist: "AirPlay"
		]

		// If we have metadata, expose it (optional but helps “ownership”)
		if let t = title, !t.isEmpty { info[MPMediaItemPropertyTitle] = t }
		if let a = artist, !a.isEmpty { info[MPMediaItemPropertyArtist] = a }
		if let al = album, !al.isEmpty { info[MPMediaItemPropertyAlbumTitle] = al }

		MPNowPlayingInfoCenter.default().nowPlayingInfo = info

		if #available(iOS 13.0, *) {
			MPNowPlayingInfoCenter.default().playbackState = active ? .playing : .paused
		}
	}

	// MARK: - Remote commands (Next/Prev) -> use existing AirAP remote control

	private func installRemoteCommandsIfNeeded() {
		guard !remoteCommandsInstalled else { return }
		remoteCommandsInstalled = true

		UIApplication.shared.beginReceivingRemoteControlEvents()

		let cc = MPRemoteCommandCenter.shared()

		// Next / Prev (steering wheel)
		cc.nextTrackCommand.isEnabled = true
		cc.previousTrackCommand.isEnabled = true

		cc.nextTrackCommand.addTarget { [weak self] _ in
			// Forward to sender via AirstreamRemote (same as AirAP UI buttons)
			DispatchQueue.main.async {
				self?.airstream?.remote?.nextItem()
			}
			// IMPORTANT: consume so local Music doesn't hijack
			return .success
		}

		cc.previousTrackCommand.addTarget { [weak self] _ in
			DispatchQueue.main.async {
				self?.airstream?.remote?.previousItem()
			}
			return .success
		}

		// Optional: swallow play/pause so the XR Music app doesn't suddenly take over.
		// (Main iPhone keeps playing anyway; this prevents “wake Music then skip = local”.)
		cc.playCommand.isEnabled = true
		cc.pauseCommand.isEnabled = true
		cc.togglePlayPauseCommand.isEnabled = true

		cc.playCommand.addTarget { _ in .success }
		cc.pauseCommand.addTarget { _ in .success }
		cc.togglePlayPauseCommand.addTarget { _ in .success }
	}

	private func uninstallRemoteCommands() {
		guard remoteCommandsInstalled else { return }
		remoteCommandsInstalled = false

		let cc = MPRemoteCommandCenter.shared()
		cc.nextTrackCommand.removeTarget(nil)
		cc.previousTrackCommand.removeTarget(nil)
		cc.playCommand.removeTarget(nil)
		cc.pauseCommand.removeTarget(nil)
		cc.togglePlayPauseCommand.removeTarget(nil)

		UIApplication.shared.endReceivingRemoteControlEvents()
	}

	// MARK: - AirstreamDelegate

	func airstream(_ airstream: Airstream, willStartStreamingWithStreamFormat streamFormat: AudioStreamBasicDescription) {
		let bytesPerFrame = Double(streamFormat.mBytesPerFrame)
		let bytesPerSecond = streamFormat.mSampleRate * bytesPerFrame
		minBufferBytes = Int32(bytesPerSecond * targetLatencySeconds)

		self.buffering = true

		var streamFormat = streamFormat

		#if canImport(AppKit)
		var desc = AudioComponentDescription(
			componentType: kAudioUnitType_Output,
			componentSubType: kAudioUnitSubType_DefaultOutput,
			componentManufacturer: kAudioUnitManufacturer_Apple,
			componentFlags: 0,
			componentFlagsMask: 0
		)
		#elseif canImport(UIKit)
		var desc = AudioComponentDescription(
			componentType: kAudioUnitType_Output,
			componentSubType: kAudioUnitSubType_RemoteIO,
			componentManufacturer: kAudioUnitManufacturer_Apple,
			componentFlags: 0,
			componentFlagsMask: 0
		)
		#endif

		if let comp = AudioComponentFindNext(nil, &desc) {
			let status = AudioComponentInstanceNew(comp, &audioUnit)
			if status != noErr {
				print("error creating new audio component instance new")
				print(status)
				return
			}
		}

		guard let audioUnit = audioUnit else { return }

		let status = AudioUnitSetProperty(
			audioUnit,
			kAudioUnitProperty_StreamFormat,
			kAudioUnitScope_Input,
			0,
			&streamFormat,
			UInt32(MemoryLayout.size(ofValue: streamFormat))
		)
		if status != noErr {
			print("error enabling input")
			print(status)
			return
		}

		var renderCallback: AURenderCallbackStruct = AURenderCallbackStruct(
			inputProc: OutputRenderCallback,
			inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
		)
		let setupStatus = AudioUnitSetProperty(
			audioUnit,
			kAudioUnitProperty_SetRenderCallback,
			kAudioUnitScope_Global,
			0,
			&renderCallback,
			UInt32(MemoryLayout.size(ofValue: renderCallback))
		)
		if setupStatus != noErr {
			print("failed to setup callbacks")
			print(setupStatus)
			return
		}

		let initStatus = AudioUnitInitialize(audioUnit)
		if initStatus != noErr {
			print("failed to init audio unit")
			print(initStatus)
			return
		}

		let unitStatus = AudioOutputUnitStart(audioUnit)
		if unitStatus != noErr {
			print("failed to start audio unit")
			print(unitStatus)
			return
		}
	}

	func airstream(
		_ airstream: Airstream,
		processAudio buffer: UnsafeMutablePointer<CChar>,
		length: Int32
	) {
		let audioBuffer = AudioBuffer(
			mNumberChannels: UInt32(airstream.channelsPerFrame),
			mDataByteSize: UInt32(length),
			mData: buffer
		)
		let bufferList = AudioBufferList(
			mNumberBuffers: 1,
			mBuffers: audioBuffer
		)

		TPCircularBufferProduceBytes(
			&circularBuffer,
			bufferList.mBuffers.mData,
			bufferList.mBuffers.mDataByteSize
		)

		let fillCount = TPCircularBufferFillCount(&circularBuffer)
		self.buffering = fillCount < minBufferBytes
	}

	func airstreamDidStopStreaming(_ airstream: Airstream) {
		TPCircularBufferClear(&circularBuffer)

		if let audioUnit = audioUnit {
			let status = AudioOutputUnitStop(audioUnit)
			if status != noErr {
				print("failed to stop audio unit")
			}
		}
		audioUnit = nil

		DispatchQueue.main.async {
			self.canControl = false
			self.updateNowPlaying(active: false)
		}
	}

	func airstream(_ airstream: Airstream, didSetCoverart coverart: Data) {
		guard let uiimage = UIImage(data: coverart) else {
			albumArt = nil
			return
		}
		guard uiimage != albumArt else { return }
		withAnimation {
			albumArt = uiimage
		}
	}

	func airstream(_ airstream: Airstream, didSetMetadata metadata: [String : String]) {
		withAnimation {
			title = metadata["minm"]
			album = metadata["asal"]
			artist = metadata["asar"]
		}
		// Refresh now playing ownership/metadata
		updateNowPlaying(active: running)
	}

	func airstream(_ airstream: Airstream, didGainAccessTo remote: AirstreamRemote) {
		withAnimation {
			canControl = true
		}
	}

	let OutputRenderCallback: AURenderCallback = { (
		inRefCon,
		ioActionFlags,
		inTimeStamp,
		inBusNumber,
		inNumberFrames,
		ioData
	) in
		let manager = Unmanaged<AirstreamManager>.fromOpaque(inRefCon).takeUnretainedValue()

		if TPCircularBufferFillCount(&manager.circularBuffer) == 0 || manager.buffering {
			for _ in 0..<Int(ioData!.pointee.mNumberBuffers) {
				memset(
					ioData!.pointee.mBuffers.mData,
					0,
					Int(ioData!.pointee.mBuffers.mDataByteSize)
				)
			}
			return noErr
		}

		var availableBytes: UInt32 = 0
		let sourceBuffer = TPCircularBufferTail(&manager.circularBuffer, &availableBytes)
		let amount = min(ioData!.pointee.mBuffers.mDataByteSize, availableBytes)

		memcpy(ioData!.pointee.mBuffers.mData, sourceBuffer, Int(amount))
		TPCircularBufferConsume(&manager.circularBuffer, amount)

		return noErr
	}
}
