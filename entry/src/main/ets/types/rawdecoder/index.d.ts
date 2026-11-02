declare const rawdecoder: {
  extractPreview(data: Uint8Array): Uint8Array | undefined;
  decode(data: Uint8Array): Array<number> | undefined;
  decodeWithThr(data: Uint8Array, threshold: number): Array<number> | undefined;
};

export default rawdecoder;
