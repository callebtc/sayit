import Foundation

enum VoiceClonePassage {
    static func text(language: String?, targetDuration: TimeInterval) -> String {
        let code = language?.lowercased().split(separator: "-").first
        let short: String
        let extensionText: String
        switch code {
        case "de":
            short = "Am frühen Morgen öffnete ich das Fenster und hörte die Stadt langsam erwachen. Eine klare Stimme trägt ruhige Gedanken, kleine Pausen und freundliche Wärme."
            extensionText = "Ein gleichmäßiges Lesetempo lässt jedes Wort entspannt, deutlich und leicht verständlich bleiben."
        case "fr":
            short = "Au début du matin, j’ai ouvert la fenêtre et écouté la ville se réveiller. Une voix claire porte des pensées calmes, de petites pauses et une chaleur naturelle."
            extensionText = "Un rythme régulier aide chaque mot à rester détendu, distinct et facile à comprendre."
        case "es":
            short = "Temprano por la mañana abrí la ventana y escuché cómo despertaba la ciudad. Una voz clara transmite ideas tranquilas, pequeñas pausas y una calidez natural."
            extensionText = "Leer a un ritmo uniforme ayuda a que cada palabra suene relajada, clara y fácil de entender."
        case "zh":
            short = "清晨，我打开窗户，听见城市慢慢苏醒。清晰自然的声音能表达平静的想法、轻柔的停顿和温暖的情绪。"
            extensionText = "用均匀的速度朗读，可以让每个词都保持放松、清楚，也更容易理解。"
        case "ja":
            short = "朝早く窓を開けると、街がゆっくり目を覚ます音が聞こえました。自然で明瞭な声は、穏やかな考えと小さな間、そして温かさを伝えます。"
            extensionText = "一定の速さで読むと、一つひとつの言葉が落ち着いて明瞭になり、聞き取りやすくなります。"
        case "ko":
            short = "이른 아침 창문을 열고 도시가 천천히 깨어나는 소리를 들었습니다. 맑고 자연스러운 목소리는 차분한 생각과 부드러운 쉼, 따뜻한 감정을 전합니다."
            extensionText = "일정한 속도로 읽으면 모든 단어가 편안하고 또렷하게 들려 이해하기 쉬워집니다."
        case "ru":
            short = "Рано утром я открыл окно и услышал, как город постепенно просыпается. Ясный голос передаёт спокойные мысли, мягкие паузы и естественное тепло."
            extensionText = "Ровный темп помогает каждому слову звучать спокойно, отчётливо и понятно."
        case "pt":
            short = "De manhã cedo, abri a janela e ouvi a cidade despertar devagar. Uma voz clara transmite pensamentos tranquilos, pausas suaves e um pouco de calor natural."
            extensionText = "Ler em um ritmo constante ajuda cada palavra a soar relaxada, distinta e fácil de entender."
        case "it":
            short = "Al mattino presto ho aperto la finestra e ascoltato la città che si svegliava lentamente. Una voce chiara trasmette pensieri tranquilli, pause leggere e un calore naturale."
            extensionText = "Leggere a un ritmo regolare aiuta ogni parola a rimanere rilassata, distinta e facile da capire."
        default:
            short = "Early in the morning, I opened the window and listened as the city slowly woke. A clear voice carries quiet thoughts, gentle pauses, and a little natural warmth."
            extensionText = "Reading at an even pace helps every word remain relaxed, distinct, and easy to understand."
        }
        if targetDuration >= 12 {
            return "\(short) \(extensionText)"
        }
        return short
    }
}
