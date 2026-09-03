import { TokenizerBuilder } from "lindera-wasm-ipadic-nodejs";

import type { SearchTokenizer } from "./tokenizer";

const STOP_TAGS = [
  ["接続詞", "*"],
  ["助詞", "*"],
  ["助動詞", "*"],
  ["記号", "*"],
  ["フィラー", "*"],
  ["その他", "間投"],
  ["名詞", "非自立"],
  ["名詞", "代名詞"],
  ["名詞", "接尾", "人名"],
  ["名詞", "接尾", "助動詞語幹"],
  ["動詞", "非自立"],
] as const;

let singleton: SearchTokenizer | undefined;

export function createNodeSearchTokenizer(): SearchTokenizer {
  return singleton ??= buildTokenizer();
}

function buildTokenizer(): SearchTokenizer {
  const builder = new TokenizerBuilder();
  builder.setDictionary("embedded://ipadic");
  builder.setMode("normal");
  builder.setKeepWhitespace(false);
  builder.appendCharacterFilter("unicode_normalize", { kind: "nfkc" });
  builder.appendCharacterFilter("japanese_iteration_mark", { normalize_kanji: true, normalize_kana: true });
  builder.appendTokenFilter("japanese_compound_word", {
    kind: "ipadic",
    tags: ["名詞,数", "名詞,接尾,助数詞"],
    new_tag: "名詞,数",
  });
  builder.appendTokenFilter("japanese_number", { tags: ["名詞,数"] });
  builder.appendTokenFilter("japanese_katakana_stem", { min: 3 });
  builder.appendTokenFilter("remove_diacritical_mark", { japanese: false });
  builder.appendTokenFilter("lowercase", {});
  const tokenizer = builder.build();
  return {
    tokenize(text) {
      return tokenizer.tokenize(text).flatMap((token) => {
        if (STOP_TAGS.some((tag) => tag.every((part, index) => part === "*" || token.details[index] === part))) {
          return [];
        }
        const baseForm = token.details[6];
        const surface = ["動詞", "形容詞"].includes(token.details[0] ?? "") && baseForm && baseForm !== "*"
          ? baseForm
          : token.surface;
        return surface ? [surface] : [];
      });
    },
  };
}
