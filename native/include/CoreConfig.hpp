#pragma once
#include "Policy.hpp"
#include <client/ovpncli.hpp>
// Match ovpncli.cpp's thread-local logging types across translation units.
#ifndef OPENVPN_LOG
#define OPENVPN_LOG_CLASS openvpn::ClientAPI::LogReceiver
#define OPENVPN_LOG_INFO openvpn::ClientAPI::LogInfo
#include <openvpn/log/logthread.hpp>
#endif
#include <openvpn/common/options.hpp>

namespace vv {
// Both profile validation and actual connections must use the same Core settings.
// The caller supplies content already validated by safeConfig().
inline openvpn::ClientAPI::Config coreConfig(const std::string &content, bool legacy) {
    openvpn::ClientAPI::Config config;
    config.content = content;
    config.guiVersion = "VueVPN 0.1.0";
    config.connTimeout = 20;
    config.clockTickMS = 250;
    config.tunPersist = false;
    config.googleDnsFallback = false;
    config.retryOnAuthFailed = false;
    config.enableNonPreferredDCAlgorithms = legacy;
    const auto options = openvpn::OptionList::parse_from_config_static(content, nullptr);
    const bool cert = options.exists("cert");
    const bool key = options.exists("key");
    if (cert != key)
        throw Error("unsupported_auth", "A client certificate and private key must be supplied together.");
    bool explicitClientCert = false;
    if (const auto setenv = options.get_index_ptr("setenv")) {
        for (const auto index : *setenv) {
            const auto &option = options[index];
            if (option.size() > 1 && option.ref(1) == "CLIENT_CERT") {
                explicitClientCert = true;
                break;
            }
        }
    }
    // Core derives externalPki during evaluation independently of
    // Config.disableClientCert. Adapt only an unambiguous password-only profile.
    if (options.exists("auth-user-pass") && !cert && !key && !explicitClientCert)
        config.content += "\nsetenv CLIENT_CERT 0\n";
    config.compressionMode = "no";
    const auto compress = options.get_ptr("compress");
    const auto lzo = options.get_ptr("comp-lzo");
    const auto allow = options.get_ptr("allow-compression");
    // Core's "no" rejects legacy v1 framing (including comp-lzo no).
    // Opt into receive-only compatibility when explicitly requested by this
    // profile. Never enable uplink compression, and respect an explicit ban.
    const bool denied = allow && allow->size() > 1 && allow->ref(1) == "no";
    const bool legacyFraming = compress
        ? (compress->size() < 2 || compress->ref(1) != "stub-v2")
        : lzo != nullptr;
    if (legacyFraming && !denied) config.compressionMode = "asym";
    return config;
}
}
