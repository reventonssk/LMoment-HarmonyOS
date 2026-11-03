import rawdecoder from 'librawdecoder.so';

export class RawDecoder {
  static extractPreview(data: Uint8Array): Uint8Array | undefined {
    return rawdecoder.extractPreview(data);
  }

  static decode(data: Uint8Array, threshold: number): Array<number> | undefined {
    if (threshold === 0.01) {
      return rawdecoder.decode(data);
    }
    return rawdecoder.decodeWithThr(data, threshold);
  }

  static decodeLinear(data: Uint8Array, m0: number, m1: number, m2: number,
    half: boolean): ArrayBuffer | undefined {
    return rawdecoder.decodeLinear(data, m0, m1, m2, half);
  }

  static decodeLinearSrgb(data: Uint8Array): ArrayBuffer | undefined {
    return rawdecoder.decodeLinearSrgb(data);
  }

  static freeLinear(buffer: ArrayBuffer): void {
    rawdecoder.freeLinear(buffer);
  }
}
