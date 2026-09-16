use crate::{models::*, policy};
use std::{fs, net::Ipv4Addr, path::Path};
use uuid::Uuid;
pub const MAX_PROFILE_SIZE: usize = 8 * 1024 * 1024;

pub struct Imported {
    pub profile: Profile,
    pub content: String,
}
fn invalid(message: impl Into<String>) -> AppError {
    AppError::new("invalid_profile", message)
}
pub fn read_profile(path: &Path) -> Result<Imported> {
    if !path
        .extension()
        .is_some_and(|s| s.eq_ignore_ascii_case("ovpn"))
    {
        return Err(invalid("Choose a .ovpn file."));
    }
    let content = read_bounded(path)?;
    parse(
        &content,
        path.parent(),
        path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("VPN profile"),
    )
}
fn read_bounded(path: &Path) -> Result<String> {
    use std::io::Read;
    let file = fs::File::open(path)?;
    if !file.metadata()?.is_file() {
        return Err(invalid("Profile references must be regular files."));
    }
    let mut bytes = Vec::new();
    file.take(MAX_PROFILE_SIZE as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_PROFILE_SIZE {
        return Err(invalid("Profile or certificate exceeds the 8 MiB limit."));
    }
    String::from_utf8(bytes)
        .map_err(|_| invalid("Profile and certificate files must be UTF-8 text."))
}
pub fn parse(content: &str, directory: Option<&Path>, fallback_name: &str) -> Result<Imported> {
    if content.len() > MAX_PROFILE_SIZE || content.contains('\0') {
        return Err(invalid("Invalid or oversized profile."));
    }
    let mut out = String::new();
    let mut inline: Option<String> = None;
    let mut metadata = String::new();
    let mut auth = false;
    let mut client = false;
    let mut has_remote = false;
    let mut no_pull = false;
    let mut redirected = false;
    let mut routes = Vec::new();
    let mut dns = DnsSettings::default();
    let mut protocol = "udp".to_string();
    let mut server = String::new();
    let mut save = true;
    let mut legacy = false;
    let mut warnings = Vec::new();
    let forbidden = [
        "up",
        "down",
        "route-up",
        "route-pre-down",
        "ipchange",
        "tls-verify",
        "tls-crypt-v2-verify",
        "auth-user-pass-verify",
        "client-connect",
        "client-disconnect",
        "learn-address",
        "plugin",
        "config",
        "cd",
        "chroot",
        "daemon",
        "writepid",
        "log",
        "log-append",
        "status",
        "management",
        "management-client",
        "management-query-passwords",
        "askpass",
        "pkcs11-providers",
        "cryptoapicert",
        "pkcs12",
        "engine",
        "iproute",
        "tls-export-cert",
        "auth-gen-token-secret",
        "http-proxy",
        "socks-proxy",
    ];
    let allowed_blocks = [
        "ca",
        "cert",
        "key",
        "tls-auth",
        "tls-crypt",
        "tls-crypt-v2",
        "peer-fingerprint",
    ];
    for raw in content.lines() {
        let line = raw.trim();
        if let Some(ref tag) = inline {
            out.push_str(raw);
            out.push('\n');
            if line == format!("</{tag}>") {
                inline = None;
            }
            continue;
        }
        if line.starts_with('#') {
            metadata.push_str(line.trim_start_matches('#').trim());
            metadata.push('\n');
            continue;
        }
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        if line.starts_with('<') {
            let tag = line.trim_start_matches('<').trim_end_matches('>');
            if !allowed_blocks.contains(&tag) {
                return Err(invalid(format!("Unsupported inline section: {tag}")));
            }
            inline = Some(tag.to_string());
            out.push_str(line);
            out.push('\n');
            continue;
        }
        let args = shell_words::split(line).map_err(|_| invalid("Invalid quoting in profile."))?;
        if args.is_empty() {
            continue;
        }
        let key = args[0].trim_start_matches("--");
        if forbidden.contains(&key) || key.starts_with("management-") {
            return Err(invalid(format!("Unsupported or unsafe directive: {key}")));
        }
        if key == "script-security" {
            if args.get(1).is_some_and(|v| v != "0" && v != "1") {
                return Err(invalid("External profile scripts are not supported."));
            }
            continue;
        }
        if ["dev", "dev-type"].contains(&key) && args.get(1).is_some_and(|v| v.starts_with("tap")) {
            return Err(invalid(
                "TAP profiles are not supported. Use a TUN profile.",
            ));
        }
        if ["remote", "proto"].contains(&key)
            && args.iter().any(|v| v.contains("6"))
            && args
                .iter()
                .any(|v| v.starts_with("udp6") || v.starts_with("tcp6"))
        {
            return Err(invalid("IPv6 transport is not supported in this version."));
        }
        if key == "remote" {
            let remote = args
                .get(1)
                .ok_or_else(|| invalid("Missing VPN server address."))?;
            if remote.contains(':') {
                return Err(invalid("Use an IPv4 VPN endpoint."));
            }
            has_remote = true;
            if server.is_empty() {
                server = remote.clone();
            }
            if let Some(p) = args.get(3) {
                protocol = p.clone();
            }
        }
        if key == "proto" {
            protocol = args.get(1).cloned().unwrap_or(protocol);
        }
        if key == "client" {
            client = true;
        }
        if key == "auth-user-pass" {
            if args.len() > 1 {
                return Err(invalid("Credential files are not imported. Remove the auth-user-pass filename and enter credentials in VueVPN."));
            }
            auth = true;
        }
        if key == "auth-nocache" {
            save = false;
        }
        if key == "static-challenge" {
            return Err(invalid(
                "One-time challenge authentication is not supported in this version.",
            ));
        }
        if key == "route-nopull" {
            no_pull = true;
        }
        if key == "redirect-gateway" {
            redirected = true;
        }
        if key == "route" {
            let address = args
                .get(1)
                .ok_or_else(|| invalid("Route is missing a destination."))?;
            let (address, prefix) = if let Some((a, p)) = address.split_once('/') {
                (a.to_owned(), policy::mask_prefix(p)?)
            } else {
                (
                    address.clone(),
                    policy::mask_prefix(args.get(2).map(String::as_str).unwrap_or("/32"))?,
                )
            };
            let ip = address
                .parse::<Ipv4Addr>()
                .map_err(|_| invalid("Routes must use explicit IPv4 addresses."))?;
            let r = policy::route(ip, prefix)?;
            if prefix == 0 {
                redirected = true;
            } else {
                routes.push(r);
            }
        }
        if key == "dhcp-option" && args.len() > 2 {
            match args[1].as_str() {
                "DNS" => dns.servers.push(
                    args[2]
                        .parse()
                        .map_err(|_| invalid("DNS must be an IPv4 address."))?,
                ),
                "DOMAIN" | "DOMAIN-SEARCH" | "DOMAIN-ROUTE" => {
                    dns.domains.push(policy::domain(&args[2])?)
                }
                _ => {}
            }
        }
        if key == "cipher" && args.get(1).is_some_and(|v| v.ends_with("-CBC")) {
            legacy = true;
        }
        if ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"].contains(&key) {
            let value = args
                .get(1)
                .ok_or_else(|| invalid(format!("Missing file for {key}")))?;
            if value == "[inline]" {
                continue;
            }
            let dir = directory.ok_or_else(|| invalid("External files cannot be resolved."))?;
            let data = read_bounded(&dir.join(value))?;
            if data.contains(&format!("</{key}>")) {
                return Err(invalid("Invalid certificate content."));
            }
            out.push_str(&format!("<{key}>\n{data}\n</{key}>\n"));
            if key == "tls-auth" {
                if let Some(direction) = args.get(2) {
                    if direction != "0" && direction != "1" {
                        return Err(invalid("Invalid key direction."));
                    }
                    out.push_str(&format!("key-direction {direction}\n"));
                }
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
        if out.len() > MAX_PROFILE_SIZE {
            return Err(invalid("Combined profile exceeds 8 MiB."));
        }
    }
    if out.len() > MAX_PROFILE_SIZE {
        return Err(invalid("Combined profile exceeds 8 MiB."));
    }
    if inline.is_some() {
        return Err(invalid("Unclosed certificate/key section."));
    }
    if !client || !has_remote {
        return Err(invalid("Profile must have client and remote directives."));
    }
    let meta = metadata.find('{').and_then(|start| {
        metadata
            .rfind('}')
            .and_then(|end| serde_json::from_str::<serde_json::Value>(&metadata[start..=end]).ok())
    });
    if let Some(m) = &meta {
        for feature in [
            "device_auth",
            "dynamic_firewall",
            "sso_auth",
            "restrict_client",
            "push_auth",
        ] {
            if m[feature].as_bool() == Some(true) {
                return Err(invalid(format!(
                    "Pritunl {feature} requires capabilities not supported by VueVPN."
                )));
            }
        }
    }
    let pin = meta.as_ref().and_then(|m| m["password_mode"].as_str()) == Some("pin");
    let username = meta
        .as_ref()
        .and_then(|m| m["user"].as_str())
        .unwrap_or("")
        .to_string();
    let name = meta
        .as_ref()
        .and_then(|m| m["server"].as_str())
        .unwrap_or(fallback_name)
        .to_string();
    if legacy {
        warnings.push("Profile includes an AES-CBC fallback. Compatibility is enabled only for this profile; certificate verification stays enabled.".into());
    }
    if !no_pull && !routes.is_empty() {
        warnings.push("Imported routes are preserved. All IPv4 is selected because the source profile also accepts server routing.".into());
    }
    let mode = if no_pull && !routes.is_empty() && !redirected {
        RoutingMode::Selected
    } else {
        RoutingMode::All
    };
    let mut update = ProfileUpdate {
        name,
        username,
        routing_mode: mode,
        routes,
        dns,
        allow_legacy_cipher: legacy,
    };
    policy::validate_update(&mut update)?;
    Ok(Imported {
        profile: Profile {
            id: Uuid::new_v4().to_string(),
            name: update.name,
            username: update.username,
            auth_kind: if pin {
                AuthKind::Pin
            } else if auth {
                AuthKind::UsernamePassword
            } else {
                AuthKind::Certificate
            },
            routing_mode: update.routing_mode,
            routes: update.routes,
            dns: update.dns,
            protocol,
            server,
            allow_password_save: save,
            allow_legacy_cipher: legacy,
            warnings,
            remembered: false,
        },
        content: out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    const BASE: &str = "client\ndev tun\nremote vpn.example.test 1194 udp\nauth-user-pass\n";
    #[test]
    fn preserves_split_routes_and_pin_metadata() {
        let s=format!("# {{\n# \"password_mode\": \"pin\",\n# \"user\": \"demo\"\n# }}\n{BASE}route-nopull\nroute 10.2.4.99 255.255.255.0\n<key>\nPRIVATE TEST DATA\n</key>\n");
        let p = parse(&s, None, "Test").unwrap();
        assert_eq!(p.profile.auth_kind, AuthKind::Pin);
        assert_eq!(p.profile.routing_mode, RoutingMode::Selected);
        assert_eq!(p.profile.routes[0].address.to_string(), "10.2.4.0");
        assert!(!p.content.contains("password_mode"));
    }
    #[test]
    fn default_is_full_without_explicit_split() {
        assert_eq!(
            parse(BASE, None, "Test").unwrap().profile.routing_mode,
            RoutingMode::All
        );
    }
    #[test]
    fn rejects_executable_and_unsupported_directives() {
        for x in [
            "up /tmp/script",
            "plugin /tmp/plugin",
            "dev tap",
            "auth-user-pass secrets.txt",
            "script-security 2",
            "static-challenge OTP 0",
            "management 127.0.0.1 9000",
        ] {
            assert!(parse(&format!("{BASE}{x}\n"), None, "Test").is_err(), "{x}");
        }
    }
    #[test]
    fn never_imports_pritunl_sync_secrets() {
        let s = format!("# {{\"password_mode\":\"pin\",\"sync_secret\":\"secret\"}}\n{BASE}");
        assert!(!parse(&s, None, "Test").unwrap().content.contains("secret"));
    }
    #[test]
    fn inline_and_external_validation() {
        assert!(parse(&format!("{BASE}<key>\nunfinished"), None, "Test").is_err());
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("ca.crt"), "TEST CERTIFICATE").unwrap();
        let p = parse(&format!("{BASE}ca ca.crt"), Some(temp.path()), "Test").unwrap();
        assert!(p.content.contains("<ca>\nTEST CERTIFICATE\n</ca>"));
    }
    #[test]
    fn auth_nocache_disallows_persistence() {
        assert!(
            !parse(&format!("{BASE}auth-nocache\n"), None, "Test")
                .unwrap()
                .profile
                .allow_password_save
        );
    }
}
