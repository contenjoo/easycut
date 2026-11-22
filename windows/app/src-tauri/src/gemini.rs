//! Gemini adapter shared by connection checks and editing. Never log API keys.
use serde_json::{json, Value};
use std::time::Duration;
pub const MODEL: &str = "gemini-2.5-flash-lite";
pub const SERVICE: &str = "com.contenjoo.easycut.gemini";

pub fn body(contents: &[Value], system: &str, definitions: &[Value]) -> Value {
    let mut body = json!({"contents": contents, "generationConfig": {"maxOutputTokens": 8192}});
    if !system.is_empty() { body["systemInstruction"] = json!({"parts": [{"text": system}]}); }
    if !definitions.is_empty() {
        let declarations: Vec<Value> = definitions.iter().map(|d| {
            let mut f = json!({"name": d["name"], "description": d["description"]});
            if d["input_schema"]["properties"].as_object().is_some_and(|p| !p.is_empty()) {
                f["parameters"] = d["input_schema"].clone();
            }
            f
        }).collect();
        body["tools"] = json!([{"functionDeclarations": declarations}]);
    }
    body
}

pub fn content(response: &Value) -> Result<Value, String> {
    let candidate = &response["candidates"][0];
    if !candidate["content"]["parts"].as_array().is_some_and(|p| !p.is_empty()) {
        return Err("Gemini가 응답하지 못했습니다. 요청을 바꿔 다시 시도해 주세요.".into());
    }
    match candidate["finishReason"].as_str().unwrap_or("STOP") {
        "STOP" => Ok(candidate["content"].clone()),
        "MAX_TOKENS" => Err("Gemini 응답이 길어 중단됐습니다. 요청을 나눠 주세요.".into()),
        _ => Err("Gemini가 요청을 처리하지 못했습니다. 요청 내용을 확인해 주세요.".into()),
    }
}

pub fn error_message(code: u16) -> &'static str {
    match code {
        400 | 401 => "Gemini 키 또는 요청을 확인해 주세요. 새 키를 발급해 다시 연결할 수 있습니다.",
        403 => "이 키로 Gemini를 사용할 수 없습니다. Google AI Studio에서 프로젝트 권한과 지원 지역을 확인해 주세요.",
        404 => "Gemini 모델을 사용할 수 없습니다. EasyCut 업데이트를 확인해 주세요.",
        429 => "Gemini 사용량 한도에 도달했습니다. 잠시 후 다시 시도하거나 Google AI Studio에서 한도를 확인해 주세요. 유료 모델로 자동 전환하지 않습니다.",
        500..=599 => "Gemini 서버가 혼잡합니다. 잠시 후 다시 시도해 주세요.",
        _ => "Gemini 연결에 실패했습니다. 다시 시도해 주세요.",
    }
}

pub fn request(key: &str, contents: &[Value], system: &str, definitions: &[Value]) -> Result<Value, String> {
    let url = format!("https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent");
    match ureq::post(&url).timeout(Duration::from_secs(120)).set("Content-Type", "application/json")
        .set("x-goog-api-key", key).send_json(body(contents, system, definitions)) {
        Ok(r) => {
            let response: Value = r.into_json().map_err(|_| "Gemini 응답을 읽지 못했습니다.")?;
            content(&response)
        }
        Err(ureq::Error::Status(code, _)) => Err(error_message(code).into()),
        Err(_) => Err("Gemini에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schemas_and_signatures() {
        let defs = vec![json!({"name":"get_project_state","description":"state","input_schema":{"type":"object","properties":{}}}),
            json!({"name":"add_text","description":"title","input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}})];
        let body = body(&[], "editor", &defs);
        assert!(body["tools"][0]["functionDeclarations"][0]["parameters"].is_null());
        assert_eq!(body["tools"][0]["functionDeclarations"][1]["parameters"]["required"], json!(["text"]));
        let c = json!({"role":"model","parts":[{"thoughtSignature":"opaque","functionCall":{"id":"c1","name":"add_text","args":{"text":"안녕하세요","start":0}}}]});
        assert_eq!(content(&json!({"candidates":[{"content":c,"finishReason":"STOP"}]})).unwrap(), c);
        assert!(content(&json!({"candidates":[{"content":c,"finishReason":"MAX_TOKENS"}]})).is_err());
        assert!(content(&json!({"promptFeedback":{"blockReason":"SAFETY"}})).is_err());
    }
    #[test]
    fn errors_are_actionable() {
        for code in [400,401,403,404,429,500,503] { assert!(!error_message(code).is_empty()); }
        assert!(error_message(429).contains("한도"));
    }
}
