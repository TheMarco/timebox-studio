import XCTest
import TimeboxKit

final class TimeboxPacketEncoderTests: XCTestCase {
    func testBrightnessFiftyPacket() throws {
        let packet = try TimeboxPacketEncoder.encode(.setBrightness(50))

        XCTAssertEqual(packet, Data([0x01, 0x04, 0x00, 0x74, 0x32, 0xAA, 0x00, 0x02]))
    }

    func testBrightnessBoundaryPackets() throws {
        XCTAssertEqual(
            try TimeboxPacketEncoder.encode(.setBrightness(0)),
            Data([0x01, 0x04, 0x00, 0x74, 0x00, 0x78, 0x00, 0x02])
        )
        XCTAssertEqual(
            try TimeboxPacketEncoder.encode(.setBrightness(100)),
            Data([0x01, 0x04, 0x00, 0x74, 0x64, 0xDC, 0x00, 0x02])
        )
    }

    func testLightningPlainColorRedFullBrightness() throws {
        let packet = try TimeboxPacketEncoder.encode(
            .lightningPlainColor(color: PixelRGB(red: 0xFF, green: 0x00, blue: 0x00), brightnessPercent: 100)
        )

        // 01 | LLLL=0D00 | 45 01 FF0000 64 00 01 000000 | CRCR=B701 | 02
        XCTAssertEqual(
            packet,
            Data([0x01, 0x0D, 0x00, 0x45, 0x01, 0xFF, 0x00, 0x00, 0x64, 0x00, 0x01, 0x00, 0x00, 0x00, 0xB7, 0x01, 0x02])
        )
    }

    func testRejectsColorBrightnessOutOfRange() {
        XCTAssertThrowsError(
            try TimeboxPacketEncoder.encode(
                .lightningPlainColor(color: PixelRGB(red: 0, green: 0, blue: 0), brightnessPercent: 200)
            )
        ) { error in
            XCTAssertEqual(error as? TimeboxPacketEncoderError, .brightnessOutOfRange(200))
        }
    }

    func testSolidColorImagePacket() throws {
        let red = PixelRGB(red: 0xFF, green: 0x00, blue: 0x00)
        let frame = PixelFrame(fill: red)
        let packet = try TimeboxPacketEncoder.encode(.image(frame))

        // 1 colour -> 1 bit/pixel, all index 0 -> 32 zero bytes of packed pixels.
        // payload: 44 00 0A 0A 04 | AA 2A00 000000 | 01 (NN) | FF0000 (palette) | 00*32
        var expected = Data([
            0x01, 0x31, 0x00,                          // start + LEN(0x0031)
            0x44, 0x00, 0x0A, 0x0A, 0x04,              // cmd + static-image header
            0xAA, 0x2A, 0x00, 0x00, 0x00, 0x00,        // frame marker + LLLL(0x002A) + 00 00 00
            0x01,                                      // NN = 1 colour
            0xFF, 0x00, 0x00                           // palette[0] = red
        ])
        expected.append(Data(repeating: 0x00, count: 32)) // packed pixels (all index 0)
        expected.append(Data([0x61, 0x02, 0x02]))         // CRC(0x0261, LE) + end marker 0x02
        XCTAssertEqual(packet, expected)
    }

    func testImagePalettePackingTwoColors() throws {
        // pixel 0 = red, pixel 1 = green, the rest red -> palette [red, green], 1 bit/pixel.
        var pixels = Array(repeating: PixelRGB(red: 0xFF, green: 0x00, blue: 0x00), count: 256)
        pixels[1] = PixelRGB(red: 0x00, green: 0xFF, blue: 0x00)
        let payload = TimeboxImageEncoder.imagePayload(frame: try PixelFrame(pixels: pixels))

        // header(5) + AA + LLLL(2) + 000000(3) = index of NN is 11
        XCTAssertEqual(Array(payload.prefix(6)), [0x44, 0x00, 0x0A, 0x0A, 0x04, 0xAA])
        XCTAssertEqual(payload[11], 0x02)                       // NN = 2 colours
        XCTAssertEqual(Array(payload[12..<18]), [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00]) // palette red,green
        // packed pixels start at 18: pixel1 (index 1) sets bit 1 of byte 0 -> 0x02.
        XCTAssertEqual(payload[18], 0x02)
    }

    func testRejectsBrightnessOutOfRange() {
        XCTAssertThrowsError(try TimeboxPacketEncoder.encode(.setBrightness(101))) { error in
            XCTAssertEqual(error as? TimeboxPacketEncoderError, .brightnessOutOfRange(101))
        }
    }

    func testChecksumSumsLengthAndPayloadLittleEndian() {
        let lengthAndPayload = Data([0x04, 0x00, 0x74, 0x32])

        XCTAssertEqual(TimeboxChecksum.sum16(lengthAndPayload), 0x00AA)
        XCTAssertEqual(TimeboxChecksum.littleEndianBytes(0x00AA), Data([0xAA, 0x00]))
    }
}
