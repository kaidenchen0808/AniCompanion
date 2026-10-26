import SwiftUI

// MARK: - Skill Chip

/// A selected-skill chip above the input bar (× to detach).
struct SkillChip: View {

    let skill: Skill
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.45, green: 0.7, blue: 1.0).opacity(0.85))
                .frame(width: 6, height: 6)
            Text(skill.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - Skill Picker Panel

/// The `/` panel: filtered skill list with keyboard-highlight sync.
struct SkillPickerPanel: View {

    let skills: [Skill]
    @Binding var highlightIndex: Int
    let onSelect: (Skill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple.opacity(0.85))
                Text(skills.isEmpty ? "没有匹配的技能" : "技能（↑↓ 选择，Enter 确认，Esc 取消）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                        SkillRow(skill: skill, highlighted: index == highlightIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                highlightIndex = index
                                onSelect(skill)
                            }
                            .onHover { hovering in
                                if hovering { highlightIndex = index }
                            }
                            .id(skill.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 264)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .onChange(of: highlightIndex) { _, newValue in
            guard skills.indices.contains(newValue) else { return }
        }
    }
}

private struct SkillRow: View {

    let skill: Skill
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 首字母徽章（不引外部图标库）
            ZStack {
                Circle()
                    .fill(highlighted ? Color(red: 0.45, green: 0.7, blue: 1.0).opacity(0.3) : Color.white.opacity(0.08))
                Text(String(skill.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.white.opacity(0.08) : Color.clear)
        )
    }
}
