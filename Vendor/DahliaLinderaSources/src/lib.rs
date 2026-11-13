#![allow(non_snake_case)]

use lindera::LinderaResult;
use lindera::token::Token;
use lindera_analysis::token_filter::TokenFilter;
use lindera_analysis::tokenizer::{Tokenizer, TokenizerBuilder};
use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::sync::{Arc, Mutex, OnceLock, Weak};

const CONFIG: &str = include_str!("../analyzer.yml");
const ANALYZER_VERSION: &[u8] = b"dahlia_lindera_ipadic_v1\0";
const CONFIG_HASH: &[u8] = b"e4e5d5c88f88895432fe3ec7e98b00ee2f05ca9ff6d78b47dda780ba6f5f308c\0";

const OK: i32 = 0;
const INVALID_ARGUMENT: i32 = 1;
const CONFIGURATION_ERROR: i32 = 2;
const TOKENIZATION_ERROR: i32 = 3;
const CALLBACK_ERROR: i32 = 4;
const PANIC: i32 = 5;

type TokenCallback = unsafe extern "C" fn(
    context: *mut c_void,
    token: *const u8,
    token_length: usize,
    start_offset: i32,
    end_offset: i32,
) -> i32;

struct Analyzer {
    tokenizer: Arc<Tokenizer>,
}

#[derive(Clone)]
struct UserDictionaryBaseFormFilter;

impl TokenFilter for UserDictionaryBaseFormFilter {
    fn name(&self) -> &'static str {
        "dahlia_user_dictionary_base_form"
    }

    fn apply(&self, tokens: &mut Vec<Token<'_>>) -> LinderaResult<()> {
        // The 3-column CSV loader fills base_form with `*`; preserve its surface before base-form normalization.
        for token in tokens {
            if !token.word_id.is_system() && token.get("base_form") == Some("*") {
                token.set_detail(6, token.surface.clone());
            }
        }
        Ok(())
    }
}

fn build_analyzer_with_dictionaries(
    dictionary: Option<&str>,
    user_dictionary: Option<&str>,
) -> Result<Analyzer, ()> {
    type Key = (Option<String>, Option<String>);
    static CACHE: OnceLock<Mutex<HashMap<Key, Weak<Tokenizer>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = (
        dictionary.map(str::to_owned),
        user_dictionary.map(str::to_owned),
    );
    {
        let mut entries = cache.lock().map_err(|_| ())?;
        entries.retain(|_, value| value.strong_count() > 0);
        if let Some(tokenizer) = entries.get(&key).and_then(Weak::upgrade) {
            return Ok(Analyzer { tokenizer });
        }
    }
    let yaml: serde_yaml_ng::Value = serde_yaml_ng::from_str(CONFIG).map_err(|_| ())?;
    let config: serde_json::Value = serde_json::to_value(yaml).map_err(|_| ())?;
    let mut builder = TokenizerBuilder::from_config(config).map_err(|_| ())?;
    if let Some(uri) = dictionary {
        builder.set_segmenter_dictionary(uri);
    }
    if let Some(uri) = user_dictionary {
        builder.set_segmenter_user_dictionary(uri);
    }
    let mut tokenizer = builder.build().map_err(|_| ())?;
    if let Some(user) = &tokenizer.segmenter.user_dictionary {
        let matrix = &tokenizer.segmenter.dictionary.connection_cost_matrix;
        // Lindera-dictionary 6.2.0 stores 10-byte WordEntry records; its CSV loader does not bound context IDs.
        for entry in user.dict.vals_data.chunks_exact(10) {
            let left = u16::from_le_bytes([entry[6], entry[7]]) as u32;
            let right = u16::from_le_bytes([entry[8], entry[9]]) as u32;
            if left >= matrix.backward_size || right >= matrix.forward_size {
                return Err(());
            }
        }
    }
    if user_dictionary.is_some() {
        tokenizer
            .token_filters
            .insert(0, UserDictionaryBaseFormFilter.into());
    }
    // Tokenizers are immutable; reuse their large dictionaries without serializing tokenization.
    let tokenizer = Arc::new(tokenizer);
    let mut entries = cache.lock().map_err(|_| ())?;
    let tokenizer = entries
        .get(&key)
        .and_then(Weak::upgrade)
        .unwrap_or(tokenizer);
    entries.insert(key, Arc::downgrade(&tokenizer));
    Ok(Analyzer { tokenizer })
}

fn build_analyzer() -> Result<Analyzer, ()> {
    build_analyzer_with_dictionaries(None, None)
}

/// Paths are UTF-8 C strings owned by the caller for this call only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dahlia_lindera_create_with_dictionaries(
    dictionary: *const c_char,
    user_dictionary: *const c_char,
    handle: *mut *mut c_void,
) -> i32 {
    if handle.is_null() {
        return INVALID_ARGUMENT;
    }
    unsafe {
        *handle = std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let dictionary = if dictionary.is_null() {
            None
        } else {
            Some(
                unsafe { CStr::from_ptr(dictionary) }
                    .to_str()
                    .map_err(|_| ())?,
            )
        };
        let user_dictionary = if user_dictionary.is_null() {
            None
        } else {
            Some(
                unsafe { CStr::from_ptr(user_dictionary) }
                    .to_str()
                    .map_err(|_| ())?,
            )
        };
        build_analyzer_with_dictionaries(dictionary, user_dictionary)
    }));
    match result {
        Ok(Ok(analyzer)) => {
            unsafe {
                *handle = Box::into_raw(Box::new(analyzer)).cast::<c_void>();
            }
            OK
        }
        Ok(Err(())) => CONFIGURATION_ERROR,
        Err(_) => PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dahlia_lindera_create(handle: *mut *mut c_void) -> i32 {
    if handle.is_null() {
        return INVALID_ARGUMENT;
    }
    match catch_unwind(build_analyzer) {
        Ok(Ok(analyzer)) => {
            let analyzer = Box::into_raw(Box::new(analyzer)).cast::<c_void>();
            unsafe { *handle = analyzer };
            OK
        }
        Ok(Err(())) => CONFIGURATION_ERROR,
        Err(_) => PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dahlia_lindera_delete(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(handle.cast::<Analyzer>()));
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn dahlia_lindera_tokenize(
    handle: *mut c_void,
    input: *const u8,
    input_length: usize,
    context: *mut c_void,
    callback: Option<TokenCallback>,
) -> i32 {
    if handle.is_null() || (input.is_null() && input_length != 0) || callback.is_none() {
        return INVALID_ARGUMENT;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let analyzer = unsafe { &mut *handle.cast::<Analyzer>() };
        let bytes = if input_length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(input, input_length) }
        };
        let text = std::str::from_utf8(bytes).map_err(|_| INVALID_ARGUMENT)?;
        let mut tokens = analyzer
            .tokenizer
            .tokenize(text)
            .map_err(|_| TOKENIZATION_ERROR)?;
        let callback = callback.expect("validated above");
        for token in &mut tokens {
            let surface = token.surface.as_bytes();
            let result = unsafe {
                callback(
                    context,
                    surface.as_ptr(),
                    surface.len(),
                    token
                        .byte_start
                        .try_into()
                        .map_err(|_| TOKENIZATION_ERROR)?,
                    token.byte_end.try_into().map_err(|_| TOKENIZATION_ERROR)?,
                )
            };
            if result != 0 {
                return Err(CALLBACK_ERROR);
            }
        }
        Ok(OK)
    })) {
        Ok(Ok(status)) => status,
        Ok(Err(status)) => status,
        Err(_) => PANIC,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dahlia_lindera_analyzer_version() -> *const c_char {
    ANALYZER_VERSION.as_ptr().cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn dahlia_lindera_config_hash() -> *const c_char {
    CONFIG_HASH.as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_configuration_builds_and_normalizes() {
        let analyzer = build_analyzer().expect("configuration should build");
        let tokens = analyzer
            .tokenizer
            .tokenize("Ｌｉｎｄｅｒａで話した")
            .expect("tokenization should succeed");
        let surfaces: Vec<&str> = tokens.iter().map(|token| token.surface.as_ref()).collect();
        assert!(surfaces.contains(&"lindera"));
        assert!(surfaces.contains(&"話す"));
    }

    #[test]
    fn analyzers_share_immutable_tokenizers() {
        let first = build_analyzer().unwrap();
        let second = build_analyzer().unwrap();
        assert!(Arc::ptr_eq(&first.tokenizer, &second.tokenizer));
    }

    #[test]
    fn user_csv_extends_tokens_and_rejects_out_of_range_context_ids() {
        let path = std::env::temp_dir().join(format!(
            "dahlia-user-dictionary-{}-{}.csv",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, "ダリア会議,カスタム名詞,ダリアカイギ\n").unwrap();
        let analyzer = build_analyzer_with_dictionaries(None, path.to_str()).unwrap();
        let tokens = analyzer.tokenizer.tokenize("ダリア会議").unwrap();
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].surface, "ダリア会議");
        drop(tokens);
        drop(analyzer);
        std::fs::write(&path, "ダリア会議,65535,65535,-10000,名詞,固有名詞,一般,*,*,*,ダリア会議,ダリアカイギ,ダリアカイギ\n").unwrap();
        assert!(build_analyzer_with_dictionaries(None, path.to_str()).is_err());
        std::fs::remove_file(path).unwrap();
    }
}
