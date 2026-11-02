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
}
