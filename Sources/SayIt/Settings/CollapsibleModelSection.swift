import SayItCore
import SwiftUI

struct CollapsibleModelSection: View {
    @Binding var isExpanded: Bool
    let models: [ModelDescriptor]
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        Section {
            ModelDisclosureRow(
                isExpanded: $isExpanded,
                count: models.count,
                title: title,
                detail: detail,
                tint: tint
            )
            if isExpanded {
                ForEach(models) { model in
                    ModelRowView(model: model)
                        .transition(
                            .opacity.combined(with: .move(edge: .top))
                        )
                }
            }
        }
    }
}
