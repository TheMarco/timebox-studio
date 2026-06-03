import Foundation

/// Encodes a 16x16 `PixelFrame` into the Timebox Evo static-image payload.
///
/// Format (reverse-engineered from the official app's native `pixelEncode`, and
/// matching the open `node-divoom-timebox-evo` reimplementation):
///
///     44 00 0A 0A 04  AA  LLLL  00 00 00  NN  <palette RGB...>  <packed pixels...>
///
/// - `44` = `SPP_SET_BOX_COLOR` command.
/// - `00 0A 0A 04` = fixed static-image header.
/// - `AA` = frame marker; `LLLL` = full frame length (little-endian) counting
///   from `AA` through the end of the packed pixels (i.e. `6 + body.count`).
/// - `00 00 00` = static-image time/reset bytes.
/// - `NN` = palette colour count mod 256 (256 colours -> `00`).
/// - palette: `NN` colours, 3 bytes RGB each, in first-seen order.
/// - pixels: each pixel's palette index packed LSB-first using
///   `max(1, ceil(log2(NN)))` bits per pixel, in row-major order (top-left first).
///
/// The returned bytes are the inner payload; wrap them with
/// `TimeboxPacketEncoder.encodePayload` for the `01 LEN … CRC 02` envelope.
public enum TimeboxImageEncoder {
    static let header: [UInt8] = [0x44, 0x00, 0x0A, 0x0A, 0x04]

    public static func imagePayload(frame: PixelFrame) -> Data {
        // 1. Build palette (unique colours, first-seen order) + per-pixel indices.
        var palette: [PixelRGB] = []
        var indexForColor: [UInt32: Int] = [:]
        var pixelIndices: [Int] = []
        pixelIndices.reserveCapacity(frame.pixels.count)

        for pixel in frame.pixels {
            let key = (UInt32(pixel.red) << 16) | (UInt32(pixel.green) << 8) | UInt32(pixel.blue)
            if let existing = indexForColor[key] {
                pixelIndices.append(existing)
            } else {
                let index = palette.count
                indexForColor[key] = index
                palette.append(pixel)
                pixelIndices.append(index)
            }
        }

        let colorCount = palette.count

        // 2. Bits per pixel = smallest b with 2^b >= colorCount, minimum 1.
        var bits = 0
        while (1 << bits) < colorCount { bits += 1 }
        if bits == 0 { bits = 1 }

        // 3. Pack indices LSB-first into a continuous little-endian bit stream.
        var packed = Data()
        var current: UInt16 = 0
        var filled = 0
        for index in pixelIndices {
            for bit in 0..<bits {
                if (index >> bit) & 1 == 1 {
                    current |= (1 << UInt16(filled))
                }
                filled += 1
                if filled == 8 {
                    packed.append(UInt8(current & 0xFF))
                    current = 0
                    filled = 0
                }
            }
        }
        if filled > 0 {
            packed.append(UInt8(current & 0xFF))
        }

        // 4. Frame body = NN + palette + packed pixels.
        var body = Data()
        body.append(UInt8(colorCount % 256))
        for color in palette {
            body.append(color.red)
            body.append(color.green)
            body.append(color.blue)
        }
        body.append(packed)

        // 5. Frame = AA + LLLL(LE) + 00 00 00 + body, LLLL = 6 + body.count.
        let frameLength = 6 + body.count
        var payload = Data(header)
        payload.append(0xAA)
        payload.append(UInt8(frameLength & 0xFF))
        payload.append(UInt8((frameLength >> 8) & 0xFF))
        payload.append(contentsOf: [0x00, 0x00, 0x00])
        payload.append(body)
        return payload
    }
}
