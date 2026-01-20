//
//  StartStopButton.swift
//  AirAP
//
//  Created by neon443 on 20/05/2025.
//

import SwiftUI
import UIKit

struct StartStopButton: View {
	@ObservedObject var ASmanager: AirstreamManager
	
	var body: some View {
		Button {
			ASmanager.startStop()
			UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
		} label: {
			Label(
				ASmanager.running ? "Stop" : "Start",
				systemImage: ASmanager.running ? "stop.fill" : "airplayaudio"
			)
			.font(.title2)
			.font(.body.weight(.bold))
			.modifier(monospacedIfAv())
		}
		.buttonStyle(.borderedProminent)
		.tint(ASmanager.running ? .red : .green)
		.padding(.bottom, 5)
	}
}

#Preview {
	StartStopButton(ASmanager: AirstreamManager())
}
