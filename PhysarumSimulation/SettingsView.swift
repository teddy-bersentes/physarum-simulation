//
//  SettingsView.swift
//  Slime
//
//  Created by Teddy Bersentes on 4/18/23.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var simulationModel: SimulationModel
    @Binding var isShowing: Bool
    
    var body: some View {
        ScrollView {
            Color.clear.frame(width: 0, height: 16)
            
            VStack(alignment: .leading, spacing: 12) {
                Button(action: {
                    withAnimation {
                        isShowing.toggle()
                    }
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                        .frame(width: 12, height: 12)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }
                
                Group {
                    LabeledSlider(
                        title: "AGENT COUNT",
                        range: 100_000...7_000_000,
                        step: 100_000,
                        value: .convert($simulationModel.agentCount)
                    )
                    
                    LabeledSlider(
                        title: "SPECIES #",
                        range: 1...3,
                        step: 1,
                        value: .convert($simulationModel.configuration.species)
                    )
                    
                    LabeledSlider(
                        title: "SENSOR OFFSET",
                        range:  2...100,
                        step: 1,
                        value: $simulationModel.configuration.sensorOffset
                    )
                    
                    
                    LabeledSlider(
                        title: "SENSOR ANGLE SPACING",
                        range: 0.05...Float.pi - 0.05,
                        step: 0.05,
                        value: $simulationModel.configuration.sensorAngleSpacing
                    )
                    
                    LabeledSlider(
                        title: "TURN SPEED",
                        range: 0.1...100,
                        step: 0.5,
                        value: $simulationModel.configuration.turnSpeed
                    )
                    
                    LabeledSlider(
                        title: "EVAPORATION SPEED",
                        range: 0.01...0.9,
                        step: 0.01,
                        value: $simulationModel.configuration.evaporationSpeed
                    )
                    
                    LabeledSlider(
                        title: "MOVEMENT SPEED",
                        range: 0.1...200,
                        step: 0.5,
                        value: $simulationModel.configuration.moveSpeed
                    )
                    
                    LabeledSlider(
                        title: "TRAIL WEIGHT",
                        range: 0.01...1,
                        step: 0.01,
                        value: $simulationModel.configuration.trailWeight
                    )
                }
                
                Button(action: {
                    simulationModel.agentCount = simulationModel.agentCount
                }) {
                    Text("Clear Agents")
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(12)
                }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                
                Spacer()
            }
            .background { VisualEffectView(effect: UIBlurEffect(style: .regular)) }
            .cornerRadius(10)
            .frame(width: 240)
            
        }
    }
}

struct LabeledSlider: View {
    let title: String
    let range: ClosedRange<Float>
    let step: Float
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(Font.system(size: 12))
                .foregroundColor(Color.init(uiColor: .systemGray3))

            Slider(
                value: $value,
                in: range,
                step: step
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background { VisualEffectView(effect: UIBlurEffect(style: .dark)) }
    }
}

public extension Binding {
    static func convert<T: BinaryInteger, U: BinaryFloatingPoint>(_ intBinding: Binding<T>) -> Binding<U> {
        Binding<U>(
            get: { U(intBinding.wrappedValue) },
            set: { intBinding.wrappedValue = T($0) }
        )
    }

    static func convert<T: BinaryFloatingPoint, U: BinaryInteger>(_ floatBinding: Binding<T>) -> Binding<U> {
        Binding<U>(
            get: { U(floatBinding.wrappedValue) },
            set: { floatBinding.wrappedValue = T($0) }
        )
    }
}

