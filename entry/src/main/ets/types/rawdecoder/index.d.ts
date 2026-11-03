declare const rawdecoder: {
  extractPreview(data: Uint8Array): Uint8Array | undefined;
  decode(data: Uint8Array): Array<number> | undefined;
  decodeWithThr(data: Uint8Array, threshold: number): Array<number> | undefined;
  decodeLinear(data: Uint8Array, m0: number, m1: number, m2: number, half: boolean): ArrayBuffer | undefined;
  decodeLinearSrgb(data: Uint8Array): ArrayBuffer | undefined;
  freeLinear(buffer: ArrayBuffer): void;
};

export default rawdecoder;
