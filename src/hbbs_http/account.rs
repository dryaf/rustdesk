use serde_derive::Serialize;

pub struct OidcSession;

#[derive(Serialize)]
pub struct AuthResult {
    pub state_msg: String,
    pub failed_msg: String,
    pub url: Option<String>,
    pub auth_body: Option<()>,
}

impl OidcSession {
    pub fn account_auth(
        _api_server: String,
        _op: String,
        _id: String,
        _uuid: String,
        _remember_me: bool,
    ) {
    }
    pub fn auth_cancel() {}
    pub fn get_result() -> AuthResult {
        AuthResult {
            state_msg: String::new(),
            failed_msg: "Accounts are unavailable in the LAN-only build".to_owned(),
            url: None,
            auth_body: None,
        }
    }
}
