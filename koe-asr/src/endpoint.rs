//! Endpoint URL scheme validation shared by all network providers.
//!
//! Configured endpoints carry credentials plus audio/transcripts, so
//! `https://` and `wss://` are always allowed while plain `http://` and
//! `ws://` are only allowed when the host is loopback (localhost,
//! 127.0.0.0/8, ::1) — e.g. a local Ollama server. Callers may opt in to
//! plain http/ws for private-network hosts too (see
//! [`validate_endpoint_url_with`]); public hosts are never allowed in plain
//! text.
//!
//! Validation is performed on the *parsed* URL using the same `url` crate
//! that reqwest uses to build requests. Hand-rolled host extraction is
//! deliberately avoided: the WHATWG parser normalizes `\` to `/`, strips
//! userinfo, and lowercases hosts, so a confusable input like
//! `http://evil.example\@localhost/v1` is judged by the host reqwest will
//! actually connect to (`evil.example`), not by a lookalike suffix.

use url::{Host, Url};

/// Validate an endpoint URL's scheme/host before it is used for a session.
///
/// Returns a human-readable error message on failure so callers can wrap
/// it in their own error type.
pub fn validate_endpoint_url(url: &str) -> Result<(), String> {
    validate_endpoint_url_with(url, false)
}

/// Like [`validate_endpoint_url`], but when `allow_private_http` is true plain
/// http/ws is also accepted for private-network hosts (see
/// [`is_private_network_host`]). This is an explicit user opt-in: traffic to
/// those hosts — credentials included — is unencrypted.
pub fn validate_endpoint_url_with(url: &str, allow_private_http: bool) -> Result<(), String> {
    let parsed = Url::parse(url).map_err(|_| insecure_endpoint_error(url))?;
    validate_parsed_endpoint(&parsed, allow_private_http)
}

/// Validate an already-parsed URL. Used both for the initial endpoint check
/// and to re-validate every hop of an HTTP redirect chain.
pub fn validate_parsed_endpoint(parsed: &Url, allow_private_http: bool) -> Result<(), String> {
    match parsed.scheme() {
        "https" | "wss" => Ok(()),
        "http" | "ws" if is_loopback_host(parsed.host()) => Ok(()),
        "http" | "ws" if allow_private_http && is_private_network_host(parsed.host()) => Ok(()),
        _ => Err(insecure_endpoint_error(parsed.as_str())),
    }
}

/// True when `url` is a plain http/ws URL whose host is on a private network.
/// Lets callers that offer the opt-in point users at it in error messages.
pub fn is_plain_private_network_url(url: &str) -> bool {
    Url::parse(url).is_ok_and(|parsed| {
        matches!(parsed.scheme(), "http" | "ws") && is_private_network_host(parsed.host())
    })
}

/// Maximum number of redirect hops followed before the chain is failed.
const MAX_REDIRECT_HOPS: usize = 10;

/// A reqwest redirect policy that only follows *same-origin* redirects.
///
/// reqwest follows redirects by default. Re-validating the scheme/host of each
/// hop is not enough:
///
/// * reqwest strips `Authorization` on a cross-host redirect, but **not**
///   custom credential headers — Koe sends the user's key as `api-key` /
///   `x-api-key` / `Authorization` depending on provider — so a 307/308 to
///   another HTTPS host would hand the API key to that host.
/// * `https://provider` → `http://127.0.0.1:…` passes a per-hop scheme check
///   (plain http is allowed for loopback) yet turns a remote request into an
///   SSRF probe of the user's local services.
///
/// So a hop is followed only when its scheme, host and effective port all
/// match the URL the chain *started* at (`attempt.previous()[0]`). Same-origin
/// path-only redirects — the only kind a real API endpoint needs — keep
/// working, including for a plain `http://127.0.0.1:11434/v1` Ollama endpoint.
/// Anything else fails the request with an error rather than silently
/// returning the 30x response, so a redirect can never be mistaken for a
/// successful call.
pub fn validating_redirect_policy() -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(|attempt| {
        match check_redirect(attempt.previous(), attempt.url()) {
            Ok(()) => attempt.follow(),
            Err(e) => attempt.error(e),
        }
    })
}

/// Decide a single redirect hop. `previous` is reqwest's redirect chain, whose
/// first entry is the original request URL (not itself a redirect); `next` is
/// the proposed hop. `Ok(())` means follow, `Err(msg)` means fail the request.
///
/// Split out from the policy closure because reqwest exposes no way to build a
/// `redirect::Attempt` or inspect a `redirect::Action`, so this is the only
/// testable surface.
fn check_redirect(previous: &[Url], next: &Url) -> Result<(), String> {
    // `previous` includes the original request URL, so its length is the
    // number of hops already taken plus one.
    if previous.len() > MAX_REDIRECT_HOPS {
        return Err("too many redirects".to_string());
    }

    let Some(original) = previous.first() else {
        return Err("redirect blocked: no original request URL to compare against".to_string());
    };

    // Cheap sanity check first so a redirect to e.g. ftp:// reports the more
    // specific scheme error. Private-network http is accepted here because the
    // origin check below pins every hop to the original URL, which the caller
    // already validated under its own policy.
    validate_parsed_endpoint(next, true).map_err(|e| format!("redirect blocked: {e}"))?;

    let (Some(next_host), Some(original_host)) = (next.host_str(), original.host_str()) else {
        return Err(format!(
            "redirect blocked: {} or {} has no host",
            original.as_str(),
            next.as_str()
        ));
    };

    // The WHATWG parser already lowercases hosts and normalizes IPs, so a
    // plain comparison is enough. `port_or_known_default` makes
    // `https://h` and `https://h:443` the same origin, while `https://h:8443`
    // is a different one.
    if next.scheme() != original.scheme()
        || next_host != original_host
        || next.port_or_known_default() != original.port_or_known_default()
    {
        return Err(format!(
            "redirect blocked: {} is a different origin than {} \
             (scheme, host and port must all match) — following it would \
             forward the configured API credentials to another host",
            next.as_str(),
            original.as_str()
        ));
    }

    Ok(())
}

fn insecure_endpoint_error(url: &str) -> String {
    format!(
        "insecure endpoint {url}: use https:// or wss:// \
         (plain http/ws is only allowed for localhost)"
    )
}

fn is_loopback_host(host: Option<Host<&str>>) -> bool {
    match host {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(ip)) => ip.is_loopback(),
        Some(Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    }
}

/// Hosts that are only reachable on a private network: RFC 1918 IPv4,
/// CGNAT 100.64.0.0/10 (Tailscale), link-local, IPv6 unique-local and
/// link-local, and mDNS `.local` names. Other DNS names are rejected because
/// they may resolve to a public address.
fn is_private_network_host(host: Option<Host<&str>>) -> bool {
    match host {
        Some(Host::Domain(domain)) => {
            let domain = domain.trim_end_matches('.');
            domain.len() > ".local".len() && domain.to_ascii_lowercase().ends_with(".local")
        }
        Some(Host::Ipv4(ip)) => {
            let [a, b, ..] = ip.octets();
            ip.is_private() || ip.is_link_local() || (a == 100 && (64..128).contains(&b))
        }
        Some(Host::Ipv6(ip)) => {
            let first = ip.segments()[0];
            (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{is_plain_private_network_url, validate_endpoint_url, validate_endpoint_url_with};

    #[test]
    fn secure_schemes_always_allowed() {
        assert!(validate_endpoint_url("https://api.openai.com/v1").is_ok());
        assert!(validate_endpoint_url("wss://openspeech.bytedance.com/api/v3/sauc").is_ok());
        assert!(validate_endpoint_url("HTTPS://Example.com").is_ok());
    }

    #[test]
    fn plain_schemes_allowed_for_loopback() {
        assert!(validate_endpoint_url("http://localhost:11434/v1").is_ok());
        assert!(validate_endpoint_url("http://127.0.0.1:11434/v1").is_ok());
        assert!(validate_endpoint_url("http://127.5.5.5/v1").is_ok());
        assert!(validate_endpoint_url("ws://[::1]:9000/asr").is_ok());
        assert!(validate_endpoint_url("http://user:pass@localhost/v1").is_ok());
        assert!(validate_endpoint_url("http://user@localhost/").is_ok());
        assert!(validate_endpoint_url("http://LOCALHOST/v1").is_ok());
    }

    #[test]
    fn plain_schemes_rejected_for_remote_hosts() {
        assert!(validate_endpoint_url("http://api.example.com/v1").is_err());
        assert!(validate_endpoint_url("ws://10.0.0.5/asr").is_err());
        assert!(validate_endpoint_url("http://localhost.evil.com/v1").is_err());
        assert!(validate_endpoint_url("http://evil-localhost/v1").is_err());
    }

    #[test]
    fn private_network_http_requires_opt_in() {
        let private = [
            "http://192.168.1.10:8000/v1",
            "http://10.0.0.5/v1",
            "http://172.16.3.4/v1",
            "http://172.31.255.255/v1",
            "http://100.101.102.103:8000/v1",
            "http://169.254.10.10/v1",
            "http://[fd7a:115c:a1e0::1]:8000/v1",
            "http://[fe80::1]/v1",
            "http://gpu-box.local:8000/v1",
            "http://GPU-Box.LOCAL./v1",
            "ws://192.168.1.10/asr",
        ];
        for url in private {
            assert!(validate_endpoint_url(url).is_err(), "{url}");
            assert!(validate_endpoint_url_with(url, true).is_ok(), "{url}");
            assert!(is_plain_private_network_url(url), "{url}");
        }
    }

    #[test]
    fn opt_in_never_allows_public_plain_http() {
        let public = [
            "http://api.example.com/v1",
            "http://8.8.8.8/v1",
            "http://172.32.0.1/v1",
            "http://100.128.0.1/v1",
            "http://192.169.1.1/v1",
            "http://[2001:db8::1]/v1",
            "http://local/v1",
            "http://.local/v1",
            "http://evil.local.example.com/v1",
            "http://evil.example\\@192.168.1.10/v1",
            "http://192.168.1.10@evil.example/v1",
        ];
        for url in public {
            assert!(validate_endpoint_url_with(url, true).is_err(), "{url}");
            assert!(!is_plain_private_network_url(url), "{url}");
        }
        assert!(validate_endpoint_url_with("ftp://192.168.1.10/", true).is_err());
        assert!(!is_plain_private_network_url("https://192.168.1.10/v1"));
    }

    #[test]
    fn parser_confusion_vectors_rejected() {
        // The WHATWG parser (used by reqwest) treats `\` as a path separator
        // in special schemes: the real connect host is evil.example, while a
        // naive rsplit('@') host extractor would see "localhost" and allow it.
        assert!(validate_endpoint_url("http://evil.example\\@localhost/v1").is_err());
        assert!(validate_endpoint_url("ws://evil.example\\@127.0.0.1/asr").is_err());
        // Userinfo must not fool the check either way: real host is evil.example.
        assert!(validate_endpoint_url("http://localhost@evil.example/v1").is_err());
        assert!(validate_endpoint_url("http://user:pass@evil.example/v1").is_err());
    }

    #[test]
    fn unknown_or_missing_schemes_rejected() {
        assert!(validate_endpoint_url("ftp://example.com").is_err());
        assert!(validate_endpoint_url("file:///etc/passwd").is_err());
        assert!(validate_endpoint_url("example.com/v1").is_err());
        assert!(validate_endpoint_url("").is_err());
    }

    #[test]
    fn error_message_names_the_endpoint() {
        let err = validate_endpoint_url("http://api.example.com/v1").unwrap_err();
        assert!(err.contains("http://api.example.com/v1"));
        assert!(err.contains("only allowed for localhost"));
    }

    // ── redirect policy ──────────────────────────────────────────────

    use super::{check_redirect, MAX_REDIRECT_HOPS};
    use url::Url;

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    /// Convenience: one-hop chain starting at `from`, redirecting to `to`.
    fn hop(from: &str, to: &str) -> Result<(), String> {
        check_redirect(&[u(from)], &u(to))
    }

    #[test]
    fn same_origin_path_redirect_allowed() {
        assert!(hop("https://api.example.com/v1", "https://api.example.com/v2").is_ok());
        // Default port spelled out explicitly is still the same origin.
        assert!(hop(
            "https://api.example.com/v1",
            "https://api.example.com:443/v1/x"
        )
        .is_ok());
        // Query/fragment-only changes are same-origin too.
        assert!(hop(
            "https://api.example.com/v1",
            "https://api.example.com/v1?a=b"
        )
        .is_ok());
        // A locally configured Ollama endpoint keeps working across a
        // same-origin path redirect.
        assert!(hop(
            "http://127.0.0.1:11434/v1",
            "http://127.0.0.1:11434/v1/chat"
        )
        .is_ok());
        assert!(hop(
            "http://localhost:11434/v1",
            "http://localhost:11434/api/chat"
        )
        .is_ok());
    }

    #[test]
    fn cross_host_https_redirect_rejected() {
        // reqwest strips Authorization cross-host but not `api-key` /
        // `x-api-key`, so this hop would leak the user's key.
        let err = hop("https://api.example.com/v1", "https://evil.example/v1").unwrap_err();
        assert!(err.contains("different origin"), "{err}");
        assert!(err.contains("https://evil.example/v1"), "{err}");
        // Subdomains are different origins too.
        assert!(hop(
            "https://api.example.com/v1",
            "https://evil.api.example.com/v1"
        )
        .is_err());
        assert!(hop("https://api.example.com/v1", "https://example.com/v1").is_err());
    }

    #[test]
    fn https_to_loopback_http_redirect_rejected() {
        // Passes a per-hop scheme check (plain http is allowed for loopback)
        // but would turn a remote call into a request against local services.
        assert!(hop("https://api.example.com/v1", "http://127.0.0.1:11434/v1").is_err());
        assert!(hop("https://api.example.com/v1", "http://localhost/v1").is_err());
        assert!(hop("https://api.example.com/v1", "http://[::1]:8080/v1").is_err());
        // Downgrade to plaintext on the same host is also refused (by the
        // scheme check, which fires first).
        let err = hop("https://api.example.com/v1", "http://api.example.com/v1").unwrap_err();
        assert!(err.contains("redirect blocked"), "{err}");
    }

    #[test]
    fn private_network_redirects_stay_same_origin() {
        assert!(hop(
            "http://192.168.1.10:8000/v1",
            "http://192.168.1.10:8000/v1/models"
        )
        .is_ok());
        assert!(hop("http://192.168.1.10:8000/v1", "http://192.168.1.11:8000/v1").is_err());
        assert!(hop("https://api.example.com/v1", "http://192.168.1.10/v1").is_err());
    }

    #[test]
    fn port_change_redirect_rejected() {
        assert!(hop(
            "https://api.example.com/v1",
            "https://api.example.com:8443/v1"
        )
        .is_err());
        assert!(hop(
            "https://api.example.com:8443/v1",
            "https://api.example.com/v1"
        )
        .is_err());
        assert!(hop("http://127.0.0.1:11434/v1", "http://127.0.0.1:9000/v1").is_err());
    }

    #[test]
    fn scheme_change_to_non_endpoint_scheme_rejected() {
        assert!(hop("https://api.example.com/v1", "ftp://api.example.com/v1").is_err());
        assert!(hop("https://api.example.com/v1", "file:///etc/passwd").is_err());
    }

    #[test]
    fn hop_limit_is_enforced_before_origin_check() {
        // `previous` carries the original URL plus every hop taken so far, so
        // a chain of MAX_REDIRECT_HOPS + 1 entries means the limit is used up.
        let chain: Vec<Url> = (0..=MAX_REDIRECT_HOPS)
            .map(|i| u(&format!("https://api.example.com/{i}")))
            .collect();
        // Same-origin, but too deep.
        let err = check_redirect(&chain, &u("https://api.example.com/last")).unwrap_err();
        assert_eq!(err, "too many redirects");

        // Exactly at the limit: the tenth redirect is still followed.
        assert!(check_redirect(
            &chain[..MAX_REDIRECT_HOPS],
            &u("https://api.example.com/last"),
        )
        .is_ok());
    }

    #[test]
    fn empty_redirect_chain_is_refused() {
        // reqwest always supplies the original URL; if it ever did not, fail
        // closed rather than following an unanchored hop.
        assert!(check_redirect(&[], &u("https://api.example.com/v1")).is_err());
    }
}
