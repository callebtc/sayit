import Testing
@testable import SayItBackend

@Suite("Underdog Woof text normalization")
struct WoofTextNormalizerTests {
    private let normalizer = WoofTextNormalizer()

    @Test("Phone numbers are read digit by digit in groups", arguments: [
        ("Call 415-555-0199 today.", "Call four one five, five five five, zero one nine nine today."),
        ("Call (415) 555-0199.", "Call four one five, five five five, zero one nine nine."),
        ("Dial +1 415 555.0199", "Dial four one five, five five five, zero one nine nine"),
        ("Ext 555-0199.", "Ext five five five, zero one nine nine."),
        ("Text 415 555 0199 or +1 415 555 0199", "Text four one five, five five five, zero one nine nine or four one five, five five five, zero one nine nine"),
        ("Call 1-800-555-0199", "Call one, eight zero zero, five five five, zero one nine nine"),
    ])
    func phoneNumbers(input: String, expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test("Prices name their currency and minor units", arguments: [
        ("It costs $5.30.", "It costs five dollars and thirty cents."),
        ("Only $1!", "Only one dollar!"),
        ("Pay $1,250 now", "Pay one thousand two hundred fifty dollars now"),
        ("About €40 or £12.99", "About forty euros or twelve pounds and ninety nine pence"),
        ("A $0.05 fee", "A five cents fee"),
        ("Raised $2.5 million", "Raised two point five million dollars"),
    ])
    func money(input: String, expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test("Clock times keep only sentence-ending periods", arguments: [
        ("Meet at 5:30 p.m. on Friday.", "Meet at five thirty PM on Friday."),
        ("We close at 9 p.m. Bring snacks.", "We close at nine PM. Bring snacks."),
        ("Start at 9am, then 10:05 AM.", "Start at nine AM, then ten oh five AM."),
        ("Lunch is at 12:00.", "Lunch is at twelve o'clock."),
    ])
    func times(input: String, expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test("Years, decades, ordinals, and ranges read naturally", arguments: [
        ("In 2019, we grew.", "In twenty nineteen, we grew."),
        ("Since 1066 and 2005", "Since ten sixty six and two thousand five"),
        ("The 1990s and 1800", "The nineteen nineties and eighteen hundred"),
        ("She was 21st of 103rd", "She was twenty first of one hundred third"),
        ("The 2nd, 3rd, 12th, and 20th", "The second, third, twelfth, and twentieth"),
        ("Pages 10-20.", "Pages ten to twenty."),
        ("Pages 10 -20 and the 1,000th try", "Pages ten to twenty and the one thousandth try"),
        ("From 1990–1995", "From nineteen ninety to nineteen ninety five"),
    ])
    func dates(input: String, expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test("Quantities and symbols are spoken", arguments: [
        ("Up 45% to 3.5%.", "Up forty five percent to three point five percent."),
        ("Pi is 3.14.", "Pi is three point one four."),
        ("Version 2.0.1 shipped", "Version two point zero point one shipped"),
        ("1,000,000 runners and 7 dogs", "one million runners and seven dogs"),
        ("It was -5 and +3", "It was minus five and plus three"),
        ("Down -3.5%, up +5%", "Down minus three point five percent, up plus five percent"),
        ("Rose 10%-15%, a $500-1000 gap", "Rose ten percent-fifteen percent, a five hundred dollars-one thousand gap"),
        ("Add 1 +2, fell 10 -5% and 10 -3.5", "Add one plus two, fell ten minus five percent and ten minus three point five"),
        ("Total 10\n-5 fee", "Total ten minus five fee"),
        ("Owe -$5, got +€3 at −5 degrees", "Owe minus five dollars, got plus three euros at minus five degrees"),
        ("From $10 -$5, 5 − 3 is 2", "From ten dollars minus five dollars, five minus three is two"),
        ("C# 12 and the 1,000,000,000,000,000th", "C# twelve and the one quadrillionth"),
        ("Pages 10 -1,000 from 3,000 -5,000 at 10 -5 %", "Pages ten to one thousand from three thousand to five thousand at ten minus five percent"),
        ("Paid 1,234.56 for 1,250.5%", "Paid one thousand two hundred thirty four point five six for one thousand two hundred fifty point five percent"),
        ("From 3,000-5,000 and 123.4567", "From three thousand to five thousand and one hundred twenty three point four five six seven"),
        ("Ticket #42 & more", "Ticket number forty two and more"),
        ("Code 0042 and 1234567890123456", "Code zero zero four two and one two three four five six seven eight nine zero one two three four five six"),
    ])
    func quantities(input: String, expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test("Typography and accents map to Woof's alphabet")
    func typography() {
        #expect(
            normalizer.normalize("“Café” — it’s  naïve\nand fine")
                == "\"Cafe\" — it's naive and fine"
        )
    }

    @Test("Words and codes without digits are left alone")
    func plainText() {
        let text = "QX-ray, well-known, e.g. A-OK."
        #expect(normalizer.normalize(text) == text)
    }

    @Test("Number words follow American usage")
    func numberWords() {
        #expect(WoofTextNormalizer.cardinal(0) == "zero")
        #expect(WoofTextNormalizer.cardinal(115) == "one hundred fifteen")
        #expect(WoofTextNormalizer.cardinal(2_000_019) == "two million nineteen")
        #expect(WoofTextNormalizer.ordinal(101) == "one hundred first")
        #expect(WoofTextNormalizer.ordinal(40) == "fortieth")
        #expect(WoofTextNormalizer.year(1905) == "nineteen oh five")
        #expect(WoofTextNormalizer.year(2000) == "two thousand")
        #expect(WoofTextNormalizer.year(2010) == "twenty ten")
    }
}
