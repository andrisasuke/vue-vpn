#include "Policy.hpp"
#include "ServicePolicy.hpp"
#include <cassert>
#include <iostream>
using namespace vv;
template<class F>void rejects(F f,const std::string &code){try{f();assert(false);}catch(const Error &e){assert(e.code==code);}}
int main(){
    for(auto code:{kSMErrorJobNotFound,kSMErrorJobPlistNotFound,kSMErrorServiceUnavailable,kSMErrorInternalFailure})assert(retryableRegistrationError(code));
    for(auto code:{kSMErrorInvalidSignature,kSMErrorAuthorizationFailure,kSMErrorToolNotValid,kSMErrorInvalidPlist,kSMErrorLaunchDeniedByUser,kSMErrorAlreadyRegistered})assert(!retryableRegistrationError(code));
    assert(Route("10.1.2.199",24).cidr()=="10.1.2.0/24");
    assert(Route("10.0.0.0",8).overlaps(Route("10.4.5.0",24)));
    assert(!Route("10.0.0.0",16).overlaps(Route("10.1.0.0",16)));
    rejects([]{Route("1.2.3.4",33);},"invalid_route");
    assert(domain("DEV.Example.com.")=="dev.example.com");
    assert(domainOverlap("dev.example.com","example.com"));
    assert(!domainOverlap("notexample.com","example.com"));
    rejects([]{domain("dev..com");},"invalid_dns");
    // Split profiles must connect when the server sends DNS without suffixes.
    Policy split;split.routes={Route("172.22.128.0",17),Route("43.163.0.0",16),Route("43.173.0.0",16)};validate(split);
    Dns unscoped{{"10.0.0.53"},{}};
    auto fallback=effectivePolicy(split,unscoped);
    assert(!fallback.full&&fallback.routes==split.routes);
    assert(fallback.dns.servers.empty()&&fallback.dns.domains.empty());
    assert(specificRoutes(fallback)==split.routes); // No default or DNS host routes.
    Policy another;another.routes={Route("10.0.0.0",24)};checkConflict(fallback,another);
    assert(split.dns.servers.empty()&&unscoped.servers.size()==1);
    auto noDns=effectivePolicy(split,{});assert(noDns.dns.servers.empty());
    Dns scoped{{"10.0.0.53","10.0.0.53"},{"DEV.Example.test."}};
    auto inherited=effectivePolicy(split,scoped);
    assert(inherited.dns.servers==std::vector<std::string>{"10.0.0.53"});
    assert(inherited.dns.domains==std::vector<std::string>{"dev.example.test"});
    assert(specificRoutes(inherited).back()==Route("10.0.0.53",32));
    rejects([&]{checkConflict(inherited,another);},"route_conflict");
    auto full=split;full.full=true;
    assert(effectivePolicy(full,unscoped).dns.servers==unscoped.servers);
    auto domainOverride=split;domainOverride.dns.domains={"Internal.Example.test"};
    assert(effectivePolicy(domainOverride,unscoped).dns.domains==std::vector<std::string>{"internal.example.test"});
    assert(effectivePolicy(domainOverride,{}).dns.domains.empty());
    auto serverOverride=split;serverOverride.dns.servers={"10.0.0.54"};
    rejects([&]{effectivePolicy(serverOverride,unscoped);},"dns_domain_required");
    assert(effectivePolicy(serverOverride,scoped).dns.servers==serverOverride.dns.servers);
    serverOverride.dns.domains={"internal.example.test"};
    auto overridden=effectivePolicy(serverOverride,scoped);
    assert(overridden.dns.servers==serverOverride.dns.servers&&overridden.dns.domains==serverOverride.dns.domains);
    serverOverride.full=true;serverOverride.dns.domains.clear();
    assert(effectivePolicy(serverOverride,unscoped).dns.servers==serverOverride.dns.servers);
    // Recompute from desired policy so reconnect never retains old server DNS.
    assert(effectivePolicy(split,unscoped).dns.servers.empty());
    rejects([&]{effectivePolicy(split,Dns{{"127.0.0.1"},{}});},"invalid_dns");
    Policy a{true},b{true};rejects([&]{checkConflict(a,b);},"full_tunnel_conflict");
    b.full=false;b.routes={Route("10.1.0.0",16)};checkConflict(a,b);
    a.full=false;a.routes={Route("10.1.2.0",24)};rejects([&]{checkConflict(a,b);},"route_conflict");
    a.routes.clear();a.dns.servers={"10.1.2.3"};rejects([&]{checkConflict(a,b);},"route_conflict");
    a.dns.servers.clear();a.dns.domains={"example.com"};b.dns.domains={"dev.example.com"};rejects([&]{checkConflict(a,b);},"dns_conflict");
    assert(retryDelay(0)==2&&retryDelay(4)==30);rejects([]{retryDelay(5);},"retry_exhausted");
    assert(terminalEvent("AUTH_FAILED"));assert(terminalEvent("CERT_VERIFY_FAIL"));assert(!terminalEvent("TRANSPORT_ERROR"));
    for(auto directive:{"up /tmp/script","plugin /tmp/plugin","ca /etc/secret","auth-user-pass /etc/secret","dev tap","<connection>\nremote x\n</connection>"})rejects([&]{safeConfig(directive);},"invalid_profile");
    auto c=safeConfig("client\nproto udp\nremote example.test\nroute 10.0.0.0 255.0.0.0\n<key>\nTEST KEY\n</key>\n");
    assert(c.find("route 10.")==std::string::npos&&c.find("TEST KEY")!=std::string::npos&&c.find("proto udp4")!=std::string::npos);
    // Pritunl exports this compatibility hint alongside data-ciphers.
    auto compatible=safeConfig("client\nremote vpn.example.test\nignore-unknown-option data-ciphers\ndata-ciphers AES-128-GCM:AES-128-CBC\n");
    assert(compatible.find("ignore-unknown-option data-ciphers\n")!=std::string::npos);
    assert(compatible.find("data-ciphers AES-128-GCM:AES-128-CBC\n")!=std::string::npos);
    auto repeated=safeConfig("--ignore-unknown-option data-ciphers ncp-ciphers\nignore-unknown-option future-option\n");
    assert(repeated.find("ignore-unknown-option future-option")!=std::string::npos);
    // The hint must never exempt a directive from VueVPN's own validation.
    for(auto directive:{"up /tmp/script","plugin /tmp/plugin","ca /etc/secret","auth-user-pass /etc/secret","future-option yes"}) {
        rejects([&]{safeConfig(std::string("ignore-unknown-option up plugin ca auth-user-pass future-option\n")+directive);},"invalid_profile");
    }
    std::cout<<"Native policy unit tests passed.\n";
}
