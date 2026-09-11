import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#532: a Dolby Vision container record its own RPU contradicts.
///
/// A Profile 5 record over a bitstream whose VUI declares BT.2020 YCbCr with an HDR transfer is a
/// contradiction the file states itself, because IPT-PQ-c2 has no VUI code point and a genuine
/// Profile 5 leaves both fields unspecified. The RPU settles it: a Profile 5 RPU cannot carry a
/// residual or an NLQ, so an RPU that does is proof the record is wrong rather than a guess about it.
///
/// The two RPU NALs below are real, lifted from the first frame of Dolby's own Profile 5 asset and of
/// a Profile 8.1 remux, so the parse under test is the parse a source performs.
@Suite("AE#532: the RPU settles a contradicted Dolby Vision record")
struct DolbyVisionRecordAuditTests {

    // MARK: - Harness

    /// First `unspec62` NAL of Dolby's "Patterns of Nature" Profile 5 asset (189 B).
    /// `dovi_tool info`: `dovi_profile: 5`, `vdr_rpu_profile=0`, `disable_residual_flag=true`.
    private static let genuineProfile5RPU =
        "7c01190809004061b6506f003ff801ffc00fffd000000800000680000040000034000003" +
        "0200000301a2000031f06912000fc5b04432000010bea570000003000080000003008000" +
        "00042b9fea3fea3fea342b9fea3fea3fea342b9ffff000000300000300000300064207dc" +
        "e015083008007ffc0000c028215117ee42b80080040001805646f36ffede900100080003" +
        "00b01df6e009e2a002001000080800400220140000030000030000030048307d00019000" +
        "000300004262c55680"

    /// First `unspec62` NAL of a real Profile 8.1 remux (139 B).
    /// `dovi_tool info`: `dovi_profile: 8`, `vdr_rpu_profile=1`.
    private static let realProfile81RPU =
        "7c0119080908406136506f003ff801ffc00fffd000000800000680000040000034000003" +
        "0200000301a2566000035ea2566f9fceb1c256644ca00000100000030080000003008000" +
        "000301c36224301860a5e308e0514000001a63e5affff000000300000300000300060200" +
        "f80e1530100a0000030000030000030024180fa000040fa00640a3c503f380"

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2)
            return UInt8(hex[s..<e], radix: 16)!
        }
    }

    /// 2-byte HEVC NAL header (type in bits 1..6 of byte 0) + payload, the shape of a synthetic NAL.
    private static func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// Pack NALs into an AVCC (4-byte BE length prefix) packet, the framing the MP4/MKV demuxer gives.
    private static func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var out: [UInt8] = []
        for nal in nals {
            let n = nal.count
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            out.append(contentsOf: nal)
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(out.count))
        out.withUnsafeBytes { src in _ = memcpy(pkt.pointee.data, src.baseAddress, out.count) }
        return pkt
    }

    private static func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }

    // MARK: - What the RPU says

    @Test("a real Profile 5 RPU reports profile 5")
    func genuineProfile5RPUReportsFive() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.genuineProfile5RPU)])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == 5)
    }

    @Test("a real Profile 8.1 RPU reports profile 8")
    func realProfile81RPUReportsEight() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.realProfile81RPU)])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == 8)
    }

    @Test("a packet with no RPU NAL says nothing")
    func packetWithoutRPUSaysNothing() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA, 0xBB])])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == nil)
    }

    @Test("an unparseable RPU says nothing rather than guessing")
    func malformedRPUSaysNothing() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 62, payload: [0x00])])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == nil)
    }

    // MARK: - When the RPU is worth reading

    @Test("a Profile 5 record over a BT.2020 YCbCr PQ VUI is worth auditing")
    func profile5OverHDR10VUIIsAudited() {
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("a Profile 5 record over an HLG VUI is worth auditing too")
    func profile5OverHLGVUIIsAudited() {
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_ARIB_STD_B67, colorMatrix: AVCOL_SPC_BT2020_CL))
    }

    @Test("a genuine Profile 5 is never read, so it costs no packet")
    func genuineProfile5IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_UNSPECIFIED, colorMatrix: AVCOL_SPC_UNSPECIFIED))
    }

    @Test("a record that agrees with its VUI is not a contradiction")
    func profile81IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 8,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("AV1 Profile 10.0 is out of scope: its RPU is not in an unspec62 NAL")
    func av1IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_AV1, dvProfile: 10,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("a source with no Dolby Vision record is not audited")
    func nonDVIsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: nil,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    // MARK: - The verdict

    @Test("a Profile 5 record over a Profile 7 RPU is corrected to 7")
    func recordFiveRPUSevenCorrectsToSeven() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 7) == 7)
    }

    @Test("a Profile 5 record over a Profile 8 RPU is corrected to 8")
    func recordFiveRPUEightCorrectsToEight() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 8) == 8)
    }

    @Test("an RPU that agrees with the record corrects nothing")
    func agreeingRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 5) == nil)
    }

    @Test("no readable RPU leaves the record standing")
    func unreadRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: nil) == nil)
    }

    @Test("an RPU libdovi could not classify is not a profile to route on")
    func unclassifiedRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 0) == nil)
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 4) == nil)
    }
}
