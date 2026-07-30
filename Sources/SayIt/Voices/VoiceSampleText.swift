import Foundation

enum VoiceSampleText {
    static func discovery(language: String?) -> String {
        switch language?.lowercased().split(separator: "-").first {
        case "zh":
            "每一种声音都能让熟悉的文字呈现出新的色彩与节奏。"
        case "ja":
            "声が変わると、同じ言葉にも新しい色とリズムが生まれます。"
        case "ko":
            "목소리가 달라지면 익숙한 문장도 새로운 색과 리듬을 갖게 됩니다."
        case "de":
            "Jede Stimme gibt vertrauten Worten eine neue Farbe und einen eigenen Rhythmus."
        case "fr":
            "Chaque voix donne aux mots familiers une couleur et un rythme nouveaux."
        case "es":
            "Cada voz da a las palabras conocidas un color y un ritmo nuevos."
        case "it":
            "Ogni voce dona alle parole familiari un colore e un ritmo nuovi."
        case "pt":
            "Cada voz dá às palavras conhecidas uma nova cor e um ritmo próprio."
        case "ru":
            "Каждый голос придаёт знакомым словам новый оттенок и собственный ритм."
        default:
            "Every voice gives familiar words a new color, character, and rhythm."
        }
    }
}
