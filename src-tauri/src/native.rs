use crate::models::*;
use serde_json::Value;
use std::ffi::{c_char, CStr, CString};
use zeroize::{Zeroize, Zeroizing};
#[cfg(target_os = "macos")]
extern "C" {
    fn vv_request(json: *const c_char) -> *mut c_char;
    fn vv_service(op: *const c_char) -> *mut c_char;
    #[cfg(not(test))]
    fn vv_helper_identity() -> *mut c_char;
    fn vv_keychain(op: *const c_char, id: *const c_char, secret: *const c_char) -> *mut c_char;
    fn vv_free(s: *mut c_char);
}
fn cstring(s: &str) -> Result<CString> {
    CString::new(s).map_err(|_| AppError::new("invalid_input", "Input contains a null character."))
}
#[cfg(target_os = "macos")]
unsafe fn response(ptr: *mut c_char) -> Result<Value> {
    if ptr.is_null() {
        return Err(AppError::new(
            "native",
            "Native bridge returned an empty response.",
        ));
    }
    let bytes = Zeroizing::new(CStr::from_ptr(ptr).to_bytes().to_vec());
    vv_free(ptr);
    let v: Value = serde_json::from_slice(&bytes)?;
    if let Some(e) = v.get("error") {
        return Err(AppError::new(
            e["code"].as_str().unwrap_or("native"),
            e["message"].as_str().unwrap_or("Native operation failed."),
        ));
    }
    Ok(v)
}
fn wipe_value(value: &mut Value) {
    match value {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(wipe_value),
        Value::Object(o) => o.values_mut().for_each(wipe_value),
        _ => {}
    }
}
pub fn request(value: Value) -> Result<Value> {
    #[cfg(test)]
    {
        return testing::call("request", value);
    }
    #[allow(unreachable_code)]
    #[cfg(target_os = "macos")]
    {
        let mut value = value;
        let serialized = serde_json::to_string(&value).map(Zeroizing::new);
        wipe_value(&mut value);
        let serialized = serialized?;
        let c = cstring(&serialized)?;
        let result = unsafe { response(vv_request(c.as_ptr())) };
        let _wipe = Zeroizing::new(c.into_bytes_with_nul());
        result
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = value;
        Err(AppError::new("platform", "VueVPN requires macOS."))
    }
}
pub fn service(op: &str) -> Result<HelperStatus> {
    #[cfg(test)]
    {
        return Ok(serde_json::from_value(testing::call(
            "service",
            serde_json::json!({"op":op}),
        )?)?);
    }
    #[allow(unreachable_code)]
    #[cfg(target_os = "macos")]
    {
        let c = cstring(op)?;
        Ok(serde_json::from_value(unsafe {
            response(vv_service(c.as_ptr()))?
        })?)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = op;
        Ok(HelperStatus {
            status: "unsupported".into(),
            message: "macOS required".into(),
        })
    }
}
pub fn bundled_helper_id() -> Result<Option<String>> {
    #[cfg(test)]
    let value = testing::call("identity", serde_json::json!({"op":"identity"}))?;
    #[cfg(all(not(test), target_os = "macos"))]
    let value = unsafe { response(vv_helper_identity())? };
    #[cfg(all(not(test), not(target_os = "macos")))]
    let value = serde_json::json!({"buildId":null});
    Ok(serde_json::from_value(value["buildId"].clone())?)
}
pub fn keychain(op: &str, id: &str, secret: &str) -> Result<Value> {
    #[cfg(test)]
    {
        return testing::call(
            "keychain",
            serde_json::json!({"op":op,"id":id,"secret":secret}),
        );
    }
    #[allow(unreachable_code)]
    #[cfg(target_os = "macos")]
    {
        let a = cstring(op)?;
        let b = cstring(id)?;
        let c = cstring(secret)?;
        let result = unsafe { response(vv_keychain(a.as_ptr(), b.as_ptr(), c.as_ptr())) };
        let _wipe = Zeroizing::new(c.into_bytes_with_nul());
        result
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (op, id, secret);
        Err(AppError::new("platform", "Keychain requires macOS."))
    }
}

#[cfg(test)]
pub mod testing {
    use super::*;
    use std::cell::RefCell;
    type Handler = Box<dyn Fn(&str, Value) -> Result<Value>>;
    thread_local! {static HOOK:RefCell<Option<Handler>>=RefCell::new(None);}
    pub fn install(handler: Handler) {
        HOOK.with(|h| *h.borrow_mut() = Some(handler));
    }
    pub fn call(kind: &str, input: Value) -> Result<Value> {
        HOOK.with(|h| {
            h.borrow().as_ref().expect(
                "Unit tests must mock native operations; real Keychain/XPC calls are forbidden",
            )(kind, input)
        })
    }
}
