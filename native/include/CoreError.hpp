#pragma once
#include <openvpn/error/error.hpp>
#include <algorithm>
#include <regex>
#include <string>
#include <string_view>

namespace vv {
struct CoreFailure {std::string code,message;};
namespace core_diagnostic {
inline void hide(std::string &text,std::string_view value) {
    if(value.empty())return;
    for(size_t pos=0;(pos=text.find(value,pos))!=std::string::npos;pos+=10)
        text.replace(pos,value.size(),"[redacted]");
}
inline std::string_view trim(std::string_view value) {
    auto start=value.find_first_not_of(" \t\r\n");
    if(start==std::string_view::npos)return {};
    return value.substr(start,value.find_last_not_of(" \t\r\n")-start+1);
}
inline std::string detail(const std::string &raw,const std::string &profile,const std::string &username,const std::string &password) {
    // Exception messages may contain option values, credentials or PEM data.
    // Never export raw core logs, and reject oversized messages before copying.
    if(raw.size()>8192)return "Diagnostic omitted because it exceeds the safe size limit.";
    std::string text=raw;
    static const std::regex sensitive(
        R"((-----BEGIN\b|<\s*/?\s*(?:ca|cert|key|tls-auth|tls-crypt(?:-v2)?|extra-certs|pkcs12)\b|\b(?:(?:proxy[-_]?)?(?:password|passwd|passphrase|user[-_]?name)|pin|user|(?:auth|access|refresh|id|session)[-_]?token(?:[-_]?user)?|token|(?:client[-_]?)?secret|api[-_]?key|authorization|cookie|session[ _-]?id|setenv(?:-safe)?|PUSH_REPLY|CRV1|SCRV1|Bearer|Basic)\b|\b(?:key|private[ -]key)\s*[:=]))",
        std::regex::icase|std::regex::optimize);
    std::smatch match;
    if(std::regex_search(text,match,sensitive)) {
        // Fail closed at a sensitive field/block, including incomplete and
        // multiline values. Keep only the diagnostic prefix before it.
        text.resize(static_cast<size_t>(match.position()));text+="[sensitive details omitted]";
    }
    hide(text,password);hide(text,username);
    bool inBlock=false;
    for(size_t start=0;start<profile.size();) {
        auto end=profile.find('\n',start);if(end==std::string::npos)end=profile.size();
        auto line=trim(std::string_view(profile).substr(start,end-start));start=end+1;
        if(line.empty())continue;
        if(line.front()=='<'){inBlock=line.substr(0,2)!="</";continue;}
        // Also hide inline material echoed without its PEM/XML delimiters.
        if(inBlock){hide(text,line);continue;}
        auto space=line.find_first_of(" \t");auto directive=line.substr(0,space);
        if((directive=="setenv"||directive=="setenv-safe")&&space!=std::string_view::npos) {
            auto variable=trim(line.substr(space));auto value=variable.find_first_of(" \t");
            if(value!=std::string_view::npos) {
                auto secret=trim(variable.substr(value));hide(text,secret);
                if(secret.size()>1&&(secret.front()=='\''||secret.front()=='"'))hide(text,secret.substr(1,secret.size()-2));
            }
        }
    }
    // Option errors commonly quote the offending value. Keep the explanation,
    // but not arbitrary values supplied by a profile or a remote peer.
    static const std::regex quoted(R"re((^|[\s:=\[(])("[^"]*(?:"|$)|'[^']*(?:'|$)))re");
    text=std::regex_replace(text,quoted,"$1[redacted]");
    static const std::regex bracketed(R"(\[[^\]]*(?:\]|$))");
    text=std::regex_replace(text,bracketed,"[redacted]");
    static const std::regex userInfo(R"(([a-z][a-z0-9+.-]*://)[^/\s]*@)",std::regex::icase);
    text=std::regex_replace(text,userInfo,"$1[redacted]@");
    static const std::regex opaque(R"([A-Za-z0-9+/=_-]{24,})");
    text=std::regex_replace(text,opaque,"[redacted]");
    // A single bounded ASCII line is safe for both NSString and Activity.
    // Normalize only AFTER redaction so truncation cannot expose a secret prefix.
    std::string result;
    for(unsigned char c:text) {
        if(c<=32||c==127){if(!result.empty()&&result.back()!=' ')result+=' ';}
        else if(c<127)result+=static_cast<char>(c);
        else result+='?';
    }
    while(!result.empty()&&result.back()==' ')result.pop_back();
    if(result.size()>768){result.resize(765);result+="...";}
    return result;
}
}
inline CoreFailure coreFailure(const std::string &status,const std::string &raw,const std::string &profile={},const std::string &username={},const std::string &password={}) {
    CoreFailure result{"OPENVPN_ERROR",{}};
    // A label is optional. Only export known core labels, never arbitrary data
    // in the status field. Unknown errors retain the existing stop/retry policy.
    for(size_t i=1;i<openvpn::Error::N_ERRORS;++i)if(status==openvpn::Error::name(i)){result.code=status;break;}
    if(result.code=="AUTH_FAILED") {
        result.message="PIN, password, or username was rejected.";return result;
    }
    auto detail=core_diagnostic::detail(raw,profile,username,password);
    result.message="OpenVPN connection failed ("+result.code+")";
    result.message+=detail.empty()?". The engine did not provide an error description.":": "+detail;
    return result;
}
}
