import Foundation

/// The ISO 639-2/T code an fMP4 audio track's `mdhd` carries, resolved from the source container's tag.
///
/// The engine muxes ONE audio track into the variant and writes no `EXT-X-MEDIA` audio rendition, so
/// AVFoundation has nothing but that field to name the track from: without it `AVAssetTrack.languageCode`
/// is nil and every UI built on it, AVKit's audio menu included, reads "Not Specified" (AE#458).
///
/// ICU resolves ISO 639-1, ISO 639-2/T and BCP-47 subtags ("pt-BR" -> "por"), but NOT the twenty ISO 639-2/B
/// bibliographic codes, and Matroska writes exactly those ("ger", "fre", "cze"), so they are mapped first.
/// Everything else fails closed: a label ICU cannot resolve to a three-letter code writes no language at all,
/// which leaves the unlabelled-track behaviour untouched.
enum AudioLanguageMap {
    /// The twenty ISO 639-2 languages whose bibliographic code differs from the terminological one.
    /// None of these is a valid ISO 639-1 or 639-2/T code for a different language, so matching them
    /// first cannot shadow a real tag.
    private static let terminologicalByBibliographic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    static func iso639_2T(forSourceLanguage language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        if let terminological = terminologicalByBibliographic[raw] { return terminological }
        // "und" resolves to itself; writing it is the same as writing nothing, and movenc's default
        // already is und.
        guard let alpha3 = Locale.Language(identifier: raw).languageCode?.identifier(.alpha3),
              alpha3.count == 3, alpha3 != "und"
        else { return nil }
        return alpha3
    }
}
