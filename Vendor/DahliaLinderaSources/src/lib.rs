#![allow(non_snake_case)]

use lindera::tokenizer::{Tokenizer, TokenizerBuilder};
use std::ffi::{c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

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
    tokenizer: Tokenizer,
}

fn build_analyzer() -> Result<Analyzer, ()> {
    let yaml: serde_yaml_ng::Value = serde_yaml_ng::from_str(CONFIG).map_err(|_| ())?;
    let config: serde_json::Value = serde_json::to_value(yaml).map_err(|_| ())?;
    let builder = TokenizerBuilder::from_config(config).map_err(|_| ())?;
    let tokenizer = builder.build().map_err(|_| ())?;
    Ok(Analyzer { tokenizer })
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
}
