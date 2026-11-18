// Ported in part from iShareScreen src/isharescreen/proxy/media/hevc_rps.py
// (parse_sps, _parse_st_ref_pic_set, parse_slice_header_for_rps,
// HevcRpsTracker) (AGPL-3.0)
//
// Which pictures the decoder can decode correctly, from the slice headers'
// reference picture sets (H.265 7.3.6.1 / 7.3.7 / 8.3.1 / 8.3.2).
//
// Apple's HP stream is ONE HEVC sequence whose pictures are the tiles in
// turn: the tiles share one POC space (tile k of frame n has POC ≈ 4n + k)
// and one DPB, and a tile's picture may reference another tile's picture
// (captures 2026-11-18: tiles 2/3 often predict from tile 0's picture of the
// same frame, and keep one older "anchor" picture referenced for seconds).
// So a lost picture breaks exactly the later pictures whose RPS marks it
// used_by_curr — on any tile — and nothing else: a picture whose used
// references were all decoded is complete and correct (the encoder's
// reconstruction), even on a tile that just lost a picture. HEVCAssembler
// uses that to release such pictures instead of holding the tile for an IDR
// (which arrives as a large, blurry refresh: the visible "flash").
//
// `good` holds the POCs of pictures fed to the decoder whose references
// were all good (an IRAP empties the DPB, H.265 8.3.2, and starts it again).
// Only the first slice segment of a picture is parsed (Apple sends one slice
// per picture), and only its first bytes (the header). Anything unexpected —
// long-term references, scaling lists, a missing SPS/PPS — makes the
// verdict `nil` (no opinion), and the caller falls back to IRAP gating.
import Foundation

/// The SPS / PPS fields slice-header parsing needs.
struct HEVCRPSParameters: Equatable, Sendable {
    struct ShortTermRPS: Equatable, Sendable {
        /// DeltaPocS0 (negative, closest first) / DeltaPocS1 (positive).
        var negative: [(delta: Int, used: Bool)] = []
        var positive: [(delta: Int, used: Bool)] = []
        var count: Int { negative.count + positive.count }

        static func == (a: Self, b: Self) -> Bool {
            a.negative.map(\.delta) == b.negative.map(\.delta) && a.negative.map(\.used) == b.negative.map(\.used)
                && a.positive.map(\.delta) == b.positive.map(\.delta) && a.positive.map(\.used) == b.positive.map(\.used)
        }
    }

    var log2MaxPOCLsb = 8
    var shortTermSets: [ShortTermRPS] = []
    var longTermRefsPresent = false
    var separateColourPlane = false
    var widthLuma = 0, heightLuma = 0
    var log2CtbSize = 4
    // PPS (one id is all Apple sends; the first PPS is used).
    var dependentSliceSegments = false
    var outputFlagPresent = false
    var extraSliceHeaderBits = 0

    /// `sps` / `pps` are full NAL units (2-byte header included). nil when
    /// the SPS uses something this parser does not follow (scaling lists).
    init?(sps: Data, pps: Data?) {
        guard sps.count > 4 else { return nil }
        var r = HEVCBitReader(rbsp: sps.dropFirst(2))
        r.skip(4)                                         // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(r.bits(3))
        r.skip(1)
        // profile_tier_level(1, maxSubLayersMinus1)
        r.skip(8 + 32 + 48 + 8)
        var subProfile: [Bool] = [], subLevel: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 { subProfile.append(r.bit() == 1); subLevel.append(r.bit() == 1) }
        if maxSubLayersMinus1 > 0 { r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0..<maxSubLayersMinus1 {
            if subProfile[i] { r.skip(88) }
            if subLevel[i] { r.skip(8) }
        }
        _ = r.ue()                                        // sps_seq_parameter_set_id
        let chroma = r.ue()
        if chroma == 3 { separateColourPlane = r.bit() == 1 }
        widthLuma = Int(r.ue())
        heightLuma = Int(r.ue())
        if r.bit() == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }   // conformance window
        _ = r.ue(); _ = r.ue()                            // bit depths
        log2MaxPOCLsb = Int(r.ue()) + 4
        guard log2MaxPOCLsb <= 16 else { return nil }
        let orderingAll = r.bit() == 1
        for _ in 0..<(orderingAll ? maxSubLayersMinus1 + 1 : 1) { _ = r.ue(); _ = r.ue(); _ = r.ue() }
        let log2MinCb = Int(r.ue()) + 3
        log2CtbSize = log2MinCb + Int(r.ue())
        _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue()    // transform sizes / depths
        if r.bit() == 1, r.bit() == 1 { return nil }      // scaling_list_data: not followed
        r.skip(1)                                         // amp_enabled_flag
        r.skip(1)                                         // sample_adaptive_offset_enabled_flag
        if r.bit() == 1 {                                 // pcm_enabled_flag
            r.skip(8); _ = r.ue(); _ = r.ue(); r.skip(1)
        }
        let n = Int(r.ue())
        guard n <= 64 else { return nil }
        for i in 0..<n {
            guard let s = Self.parseShortTermRPS(&r, index: i, count: n, sets: shortTermSets) else { return nil }
            shortTermSets.append(s)
        }
        longTermRefsPresent = r.bit() == 1
        guard !r.isPastEnd else { return nil }            // truncated: not a real SPS
        if let pps, pps.count > 2 {
            var p = HEVCBitReader(rbsp: pps.dropFirst(2))
            _ = p.ue(); _ = p.ue()                        // pps id, sps id
            dependentSliceSegments = p.bit() == 1
            outputFlagPresent = p.bit() == 1
            extraSliceHeaderBits = Int(p.bits(3))
        }
    }

    /// st_ref_pic_set(idx) with the H.265 7.4.8 inter-RPS derivation.
    static func parseShortTermRPS(_ r: inout HEVCBitReader, index: Int, count: Int,
                                  sets: [ShortTermRPS]) -> ShortTermRPS? {
        var out = ShortTermRPS()
        if index != 0, r.bit() == 1 {                     // inter_ref_pic_set_prediction_flag
            let deltaIdx = index == count ? Int(r.ue()) + 1 : 1
            let sign = r.bit()
            let deltaRps = (1 - 2 * Int(sign)) * (Int(r.ue()) + 1)
            let refIdx = index - deltaIdx
            guard sets.indices.contains(refIdx) else { return nil }
            let ref = sets[refIdx]
            var used: [Bool] = [], useDelta: [Bool] = []
            for _ in 0...ref.count {
                let u = r.bit() == 1
                used.append(u)
                useDelta.append(u ? true : r.bit() == 1)
            }
            let nNeg = ref.negative.count, nAll = ref.count
            for j in stride(from: ref.positive.count - 1, through: 0, by: -1) {
                let d = ref.positive[j].delta + deltaRps
                if d < 0, useDelta[nNeg + j] { out.negative.append((d, used[nNeg + j])) }
            }
            if deltaRps < 0, useDelta[nAll] { out.negative.append((deltaRps, used[nAll])) }
            for j in 0..<nNeg {
                let d = ref.negative[j].delta + deltaRps
                if d < 0, useDelta[j] { out.negative.append((d, used[j])) }
            }
            for j in stride(from: nNeg - 1, through: 0, by: -1) {
                let d = ref.negative[j].delta + deltaRps
                if d > 0, useDelta[j] { out.positive.append((d, used[j])) }
            }
            if deltaRps > 0, useDelta[nAll] { out.positive.append((deltaRps, used[nAll])) }
            for j in 0..<ref.positive.count {
                let d = ref.positive[j].delta + deltaRps
                if d > 0, useDelta[nNeg + j] { out.positive.append((d, used[nNeg + j])) }
            }
            return out
        }
        let nNeg = Int(r.ue()), nPos = Int(r.ue())
        guard nNeg <= 16, nPos <= 16 else { return nil }
        var last = 0
        for _ in 0..<nNeg {
            last -= Int(r.ue()) + 1
            out.negative.append((last, r.bit() == 1))
        }
        last = 0
        for _ in 0..<nPos {
            last += Int(r.ue()) + 1
            out.positive.append((last, r.bit() == 1))
        }
        return out
    }
}

/// One picture's position and the pictures it needs.
struct HEVCPictureRefs: Equatable, Sendable {
    var nalType: Int
    var temporalID: Int
    var pocLsb: Int
    /// Delta POCs marked used_by_curr_pic (nil for an IRAP).
    var usedDeltas: [Int]

    /// Parses the first slice segment of a picture; nil when it is not one,
    /// or uses something not followed (long-term references).
    init?(slice nal: Data, params: HEVCRPSParameters) {
        guard nal.count > 3 else { return nil }
        let b0 = nal[nal.startIndex], b1 = nal[nal.startIndex + 1]
        nalType = Int(HEVCNAL.type(b0))
        temporalID = Int(b1 & 0x07) - 1
        guard nalType < 32, temporalID >= 0 else { return nil }
        var r = HEVCBitReader(rbsp: nal.dropFirst(2).prefix(160))
        guard r.bit() == 1 else { return nil }            // first_slice_segment_in_pic_flag
        let irap = (16...23).contains(nalType)
        if irap { r.skip(1) }                             // no_output_of_prior_pics_flag
        _ = r.ue()                                        // slice_pic_parameter_set_id
        r.skip(params.extraSliceHeaderBits)
        let sliceType = r.ue()
        if params.outputFlagPresent { r.skip(1) }
        if params.separateColourPlane { r.skip(2) }
        if nalType == 19 || nalType == 20 {               // IDR: POC 0, no references
            pocLsb = 0; usedDeltas = []
            return
        }
        pocLsb = Int(r.bits(params.log2MaxPOCLsb))
        let rps: HEVCRPSParameters.ShortTermRPS
        if r.bit() == 0 {                                 // short_term_ref_pic_set_sps_flag
            guard let s = HEVCRPSParameters.parseShortTermRPS(&r, index: params.shortTermSets.count,
                                                              count: params.shortTermSets.count,
                                                              sets: params.shortTermSets) else { return nil }
            rps = s
        } else {
            let n = params.shortTermSets.count
            var idx = 0
            if n > 1 {
                var bits = 0
                while (1 << bits) < n { bits += 1 }
                idx = Int(r.bits(bits))
            }
            guard params.shortTermSets.indices.contains(idx) else { return nil }
            rps = params.shortTermSets[idx]
        }
        if params.longTermRefsPresent || r.isPastEnd { return nil }   // long-term refs: not followed (Apple: off)
        if irap || sliceType == 2 {                        // CRA/BLA or an I slice: no inter refs
            usedDeltas = []
        } else {
            usedDeltas = rps.negative.filter(\.used).map(\.delta) + rps.positive.filter(\.used).map(\.delta)
        }
    }

    var isIRAP: Bool { (16...23).contains(nalType) }
    var isIDR: Bool { nalType == 19 || nalType == 20 }
    /// RASL / RADL / sub-layer non-reference pictures are not prevTid0Pic.
    var canAnchorPOC: Bool {
        temporalID == 0 && !(6...9).contains(nalType) && !(nalType <= 14 && nalType % 2 == 0)
    }
}

/// POC derivation (H.265 8.3.1) and the set of correctly decoded pictures.
struct HEVCReferenceTracker: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Every used reference was decoded: the picture decodes correctly.
        case decodable(poc: Int)
        /// It needs a picture the decoder never got (or got broken).
        case broken(poc: Int, missing: [Int])
    }

    private(set) var params: HEVCRPSParameters?
    private var prevTid0POC = 0
    private var good: Set<Int> = []
    /// Bound on `good` (the RPS holds at most 16 pictures; Apple keeps an
    /// anchor ~150 POCs back).
    static let keep = 1024

    mutating func setParameters(sps: Data, pps: Data?) {
        params = HEVCRPSParameters(sps: sps, pps: pps)
        good = []                                          // a rebuilt decoder starts empty
    }

    mutating func reset() { good = []; prevTid0POC = 0 }

    /// Classifies `nal` (the picture's first VCL NAL) in decoding order;
    /// nil = no opinion. Call `commit` for pictures actually fed.
    mutating func classify(_ nal: Data) -> (verdict: Verdict, refs: HEVCPictureRefs)? {
        guard let params, let refs = HEVCPictureRefs(slice: nal, params: params) else { return nil }
        let poc: Int
        if refs.isIDR {
            poc = 0
        } else {
            let max = 1 << params.log2MaxPOCLsb
            let prevLsb = ((prevTid0POC % max) + max) % max
            let prevMsb = prevTid0POC - prevLsb
            var msb = prevMsb
            if refs.pocLsb < prevLsb, prevLsb - refs.pocLsb >= max / 2 { msb += max }
            else if refs.pocLsb > prevLsb, refs.pocLsb - prevLsb > max / 2 { msb -= max }
            poc = msb + refs.pocLsb
        }
        if refs.canAnchorPOC { prevTid0POC = poc }
        if refs.isIRAP { return (.decodable(poc: poc), refs) }
        let missing = refs.usedDeltas.map { poc + $0 }.filter { !good.contains($0) }
        return (missing.isEmpty ? .decodable(poc: poc) : .broken(poc: poc, missing: missing), refs)
    }

    /// `poc` was fed to the decoder and decodes correctly.
    mutating func commit(poc: Int, irap: Bool) {
        if irap { good = [] }                              // the IRAP re-roots the DPB
        good.insert(poc)
        if good.count > 64 { good = good.filter { poc - $0 < Self.keep } }
    }

    /// A decode error: nothing in the DPB can be trusted until an IRAP.
    mutating func invalidate() { good = [] }

    var goodCount: Int { good.count }
}
