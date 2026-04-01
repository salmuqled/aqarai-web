declare module "bidi-js" {
  interface EmbeddingLevelsResult {
    levels: number[];
    paragraphs: { start: number; end: number; level: number }[];
  }
  interface Bidi {
    getEmbeddingLevels(str: string, baseDirection: string): EmbeddingLevelsResult;
    getReorderedString(
      str: string,
      embedLevelsResult: EmbeddingLevelsResult,
      start?: number,
      end?: number
    ): string;
  }
  function bidiFactory(): Bidi;
  export default bidiFactory;
}
