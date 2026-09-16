use crate::models::*;
use std::net::Ipv4Addr;

pub fn route(address: Ipv4Addr, prefix: u8) -> Result<Route> {
    if prefix > 32 {
        return Err(AppError::new(
            "invalid_route",
            "IPv4 prefix must be between 0 and 32.",
        ));
    }
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    Ok(Route {
        address: Ipv4Addr::from(u32::from(address) & mask),
        prefix,
    })
}
pub fn mask_prefix(value: &str) -> Result<u8> {
    if let Ok(n) = value.trim_start_matches('/').parse::<u8>() {
        if n <= 32 {
            return Ok(n);
        }
    }
    let ip = value
        .parse::<Ipv4Addr>()
        .map_err(|_| AppError::new("invalid_route", "Invalid subnet mask."))?;
    let bits = u32::from(ip);
    let n = bits.leading_ones();
    if bits != if n == 0 { 0 } else { u32::MAX << (32 - n) } {
        return Err(AppError::new(
            "invalid_route",
            "Subnet mask must be contiguous.",
        ));
    }
    Ok(n as u8)
}
pub fn overlaps(a: &Route, b: &Route) -> bool {
    let p = a.prefix.min(b.prefix);
    route(a.address, p).ok() == route(b.address, p).ok()
}
pub fn domain(value: &str) -> Result<String> {
    let d = value.trim().trim_end_matches('.').to_ascii_lowercase();
    if d.is_empty()
        || d.len() > 253
        || d.parse::<Ipv4Addr>().is_ok()
        || !d.split('.').all(|s| {
            !s.is_empty()
                && s.len() <= 63
                && !s.starts_with('-')
                && !s.ends_with('-')
                && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return Err(AppError::new(
            "invalid_dns",
            format!("Invalid internal domain: {value}"),
        ));
    }
    Ok(d)
}
pub fn domains_overlap(a: &str, b: &str) -> bool {
    a == b || a.ends_with(&format!(".{b}")) || b.ends_with(&format!(".{a}"))
}
pub fn validate_update(u: &mut ProfileUpdate) -> Result<()> {
    u.name = u.name.trim().to_string();
    if u.name.is_empty() || u.name.chars().count() > 80 || u.name.chars().any(char::is_control) {
        return Err(AppError::new(
            "invalid_name",
            "Use a profile name between 1 and 80 characters.",
        ));
    }
    if u.username.len() > 256 || u.username.contains(['\n', '\r', '\0']) {
        return Err(AppError::new("invalid_username", "Invalid username."));
    }
    if u.routes.len() > 256 || u.dns.servers.len() > 8 || u.dns.domains.len() > 32 {
        return Err(AppError::new("limit", "Too many routes or DNS entries."));
    }
    for r in &mut u.routes {
        *r = route(r.address, r.prefix)?;
        if r.prefix == 0 {
            return Err(AppError::new(
                "invalid_route",
                "Use All IPv4 traffic for a default route.",
            ));
        }
    }
    u.routes.sort_by_key(|r| (u32::from(r.address), r.prefix));
    u.routes.dedup();
    for d in &mut u.dns.domains {
        *d = domain(d)?;
    }
    u.dns.domains.sort();
    u.dns.domains.dedup();
    u.dns.servers.sort();
    u.dns.servers.dedup();
    if u.dns
        .servers
        .iter()
        .any(|a| a.is_unspecified() || a.is_multicast() || a.is_broadcast() || a.is_loopback())
    {
        return Err(AppError::new(
            "invalid_dns",
            "DNS must be a reachable IPv4 server address.",
        ));
    }
    Ok(())
}
pub fn conflict(candidate: &Profile, others: &[Profile]) -> Result<()> {
    for other in others {
        if candidate.id == other.id {
            continue;
        }
        if candidate.routing_mode == RoutingMode::All && other.routing_mode == RoutingMode::All {
            return Err(AppError::new(
                "full_tunnel_conflict",
                format!(
                    "{} already routes all IPv4 traffic. Disconnect it or use selected routes.",
                    other.name
                ),
            ));
        }
        let a = effective_routes(candidate);
        let b = effective_routes(other);
        for left in &a {
            for right in &b {
                if overlaps(left, right) {
                    return Err(AppError::new(
                        "route_conflict",
                        format!(
                            "{}/{} overlaps {}/{} in {}.",
                            left.address, left.prefix, right.address, right.prefix, other.name
                        ),
                    ));
                }
            }
        }
        for a in &candidate.dns.domains {
            for b in &other.dns.domains {
                if domains_overlap(a, b) {
                    return Err(AppError::new(
                        "dns_conflict",
                        format!("DNS domain {a} overlaps {b} in {}.", other.name),
                    ));
                }
            }
        }
    }
    Ok(())
}
fn effective_routes(p: &Profile) -> Vec<Route> {
    let mut routes = if p.routing_mode == RoutingMode::Selected {
        p.routes.clone()
    } else {
        vec![]
    };
    routes.extend(p.dns.servers.iter().map(|a| Route {
        address: *a,
        prefix: 32,
    }));
    routes
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn subnet_normalization_and_boundaries() {
        let r = route("192.168.4.99".parse().unwrap(), 24).unwrap();
        assert_eq!(r.address.to_string(), "192.168.4.0");
        assert_eq!(
            route("255.255.255.255".parse().unwrap(), 0)
                .unwrap()
                .address,
            Ipv4Addr::UNSPECIFIED
        );
        assert!(route(r.address, 33).is_err());
    }
    #[test]
    fn masks_must_be_contiguous() {
        assert_eq!(mask_prefix("255.255.0.0").unwrap(), 16);
        assert_eq!(mask_prefix("/32").unwrap(), 32);
        assert!(mask_prefix("255.0.255.0").is_err());
        assert!(mask_prefix("33").is_err());
    }
    #[test]
    fn detects_overlapping_but_not_adjacent_routes() {
        let a = route("10.1.0.0".parse().unwrap(), 16).unwrap();
        assert!(overlaps(
            &a,
            &route("10.1.5.0".parse().unwrap(), 24).unwrap()
        ));
        assert!(!overlaps(
            &a,
            &route("10.2.0.0".parse().unwrap(), 16).unwrap()
        ));
    }
    #[test]
    fn domains_have_label_boundaries() {
        assert_eq!(domain(" Dev.EXAMPLE.com. ").unwrap(), "dev.example.com");
        assert!(domains_overlap("dev.example.com", "example.com"));
        assert!(!domains_overlap("notexample.com", "example.com"));
        assert!(domain("bad..com").is_err());
        assert!(domain("-bad.com").is_err());
    }
}
