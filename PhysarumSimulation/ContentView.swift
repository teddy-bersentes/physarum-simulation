import SwiftUI

struct ContentView: View {
    let device = GetMetalDevice()
    var body: some View {
        Group {
            if let device = device {
                SlimeView(device: device)
            }
        }
   }
}

struct SlimeView: View {
    let device: MTLDevice
    @ObservedObject var simulation: SimulationModel
    @State var isShowing: Bool = false
    
    init(device: MTLDevice) {
        self.device = device
        self.simulation = .init(device: device, agentCount: 100_000)
    }
    
    var body: some View {
        ZStack {
            MetalViewRepresentable(device: device, renderer: simulation)
                .ignoresSafeArea()
            
            
            HStack {
                Spacer()
                
                if isShowing {
                    SettingsView(
                        simulationModel: simulation,
                        isShowing: $isShowing
                    )
                        .padding(.trailing, 12)
                } else {
                    VStack {
                        Button(action: {
                            withAnimation {
                                 self.isShowing.toggle()
                            }
                        }) {
                            Image(systemName: "gearshape")
                                .resizable()
                                .frame(width: 16, height: 16)
                                .foregroundColor(.white)
                                .padding(12)
                                .background {
                                    VisualEffectView(effect: UIBlurEffect(style: .regular))
                                        .cornerRadius(12)
                                }
                        }
                            .padding( 16)
                        
                        Spacer()
                    }
                        .transition(.opacity)
                }
            }
        }
    }
}
