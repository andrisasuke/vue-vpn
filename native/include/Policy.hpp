#pragma once
#include <arpa/inet.h>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace vv {
struct Error : std::runtime_error { std::string code; Error(std::string c, std::string m):runtime_error(m),code(std::move(c)){} };
inline uint32_t ip(const std::string &s) { in_addr a{}; if(inet_pton(AF_INET,s.c_str(),&a)!=1)throw Error("invalid_address","Expected an IPv4 address.");return ntohl(a.s_addr); }
inline std::string ipString(uint32_t a) { in_addr n{htonl(a)};char out[INET_ADDRSTRLEN];inet_ntop(AF_INET,&n,out,sizeof(out));return out; }
struct Route {
    uint32_t address=0; unsigned prefix=32;
    Route()=default;
    Route(const std::string &a,unsigned p):address(ip(a)),prefix(p){if(p>32)throw Error("invalid_route","Invalid IPv4 subnet.");address&=mask();}
    uint32_t mask() const {return prefix?0xffffffffu<<(32-prefix):0;}
    std::string cidr() const{return ipString(address)+"/"+std::to_string(prefix);}
    bool overlaps(const Route &b)const {auto m=prefix<b.prefix?mask():b.mask();return (address&m)==(b.address&m);}
    bool operator<(const Route &b)const{return address<b.address||(address==b.address&&prefix<b.prefix);}
    bool operator==(const Route &b)const{return address==b.address&&prefix==b.prefix;}
};
inline std::string domain(std::string s) {
    if(!s.empty()&&s.back()=='.')s.pop_back();
    std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return std::tolower(c);});
    if(s.empty()||s.size()>253)throw Error("invalid_dns","Invalid DNS domain.");
    size_t start=0;
    while(start<s.size()){auto end=s.find('.',start);if(end==std::string::npos)end=s.size();auto label=s.substr(start,end-start);
        if(label.empty()||label.size()>63||label.front()=='-'||label.back()=='-'||!std::all_of(label.begin(),label.end(),[](unsigned char c){return (c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-';}))throw Error("invalid_dns","Invalid DNS domain.");start=end+1;}
    return s;
}
inline bool domainOverlap(const std::string &a,const std::string &b) {
    auto suffix=[](const std::string &x,const std::string &y){return x.size()>y.size()&&x.compare(x.size()-y.size(),y.size(),y)==0&&x[x.size()-y.size()-1]=='.';};return a==b||suffix(a,b)||suffix(b,a);
}
struct Dns {std::vector<std::string> servers,domains;};
struct Policy { bool full=false;std::vector<Route> routes;Dns dns; };
inline void validate(Policy &p) {
    if(p.routes.size()>256||p.dns.servers.size()>8||p.dns.domains.size()>32)throw Error("limit","Too many routes or DNS entries.");
    for(auto &r:p.routes)if(r.prefix==0)throw Error("invalid_route","Choose All IPv4 for a default route.");
    for(auto &s:p.dns.servers){auto a=ip(s);if(!a||(a>>24)==127||a>=0xe0000000u)throw Error("invalid_dns","Invalid DNS server.");s=ipString(a);}
    for(auto &d:p.dns.domains)d=domain(d);
    auto unique=[](auto &v){std::sort(v.begin(),v.end());v.erase(std::unique(v.begin(),v.end()),v.end());};
    unique(p.routes);unique(p.dns.servers);unique(p.dns.domains);
}
inline Policy effectivePolicy(const Policy &desired,const Dns &pushed) {
    Policy effective=desired;
    if(desired.dns.servers.empty())effective.dns.servers=pushed.servers;
    if(desired.dns.domains.empty())effective.dns.domains=pushed.domains;
    validate(effective);
    if(!effective.full&&!effective.dns.servers.empty()&&effective.dns.domains.empty()) {
        // Server defaults without a suffix cannot form a supplemental resolver.
        // Keep system DNS in split mode, but do not discard an explicit override.
        if(!desired.dns.servers.empty())throw Error("dns_domain_required","Set internal DNS domains for this split profile, or remove its DNS servers.");
        effective.dns.servers.clear();
    }
    if(effective.dns.servers.empty())effective.dns.domains.clear();
    return effective;
}
inline std::vector<Route> specificRoutes(const Policy &p) {
    auto r=p.full?std::vector<Route>{}:p.routes;
    for(auto &s:p.dns.servers)r.emplace_back(s,32);
    return r;
}
inline void checkConflict(const Policy &a,const Policy &b) {
    if(a.full&&b.full)throw Error("full_tunnel_conflict","Another profile already routes all IPv4 traffic.");
    for(auto &x:specificRoutes(a))for(auto &y:specificRoutes(b))if(x.overlaps(y))throw Error("route_conflict","VPN routes overlap: "+x.cidr()+" and "+y.cidr()+".");
    for(auto &x:a.dns.domains)for(auto &y:b.dns.domains)if(domainOverlap(x,y))throw Error("dns_conflict","Internal DNS domains overlap.");
}
inline unsigned retryDelay(unsigned attempt) {constexpr unsigned delays[]={2,4,8,16,30};if(attempt>=5)throw Error("retry_exhausted","Reconnect limit reached.");return delays[attempt];}
inline bool terminalEvent(const std::string &event) {
    // Only explicit transport failures are retryable. Unknown failures stop safely.
    static const std::set<std::string> retryable={"CONNECTION_TIMEOUT","TRANSPORT_ERROR","NETWORK_RECV_ERROR","NETWORK_SEND_ERROR","RESOLVE_ERROR","KEEPALIVE_TIMEOUT","RECONNECTING","CLIENT_RESTART","INACTIVE_TIMEOUT"};
    return !retryable.count(event);
}
// Input to the privileged engine is self-contained: never read profile-supplied paths.
inline std::string safeConfig(const std::string &content) {
    if(content.size()>8*1024*1024||content.find('\0')!=std::string::npos)throw Error("invalid_profile","Invalid profile size or content.");
    static const std::set<std::string> allowed={"client","dev","dev-type","proto","remote","remote-random","remote-random-hostname","resolv-retry","nobind","persist-key","persist-tun","auth-user-pass","auth-nocache","auth-retry","auth","cipher","data-ciphers","data-ciphers-fallback","ncp-ciphers","key-direction","remote-cert-tls","remote-cert-ku","remote-cert-eku","verify-x509-name","tls-version-min","tls-version-max","tls-cipher","tls-ciphersuites","tls-cert-profile","tls-client","reneg-sec","reneg-bytes","reneg-pkts","hand-window","tran-window","tls-timeout","ping","ping-restart","ping-exit","keepalive","connect-retry","connect-retry-max","connect-timeout","server-poll-timeout","explicit-exit-notify","tun-mtu","tun-mtu-extra","mssfix","sndbuf","rcvbuf","verb","mute","mute-replay-warnings","float","fast-io","comp-lzo","compress","allow-compression","setenv","setenv-safe","route","route-nopull","route-delay","route-metric","route-gateway","redirect-gateway","redirect-private","dhcp-option","dns","topology","ifconfig","pull","pull-filter","push-peer-info","peer-fingerprint","replay-window","route-ipv6","ifconfig-ipv6","block-ipv6"};
    static const std::set<std::string> tags={"ca","cert","key","tls-auth","tls-crypt","tls-crypt-v2","peer-fingerprint"};
    std::string out,tag;size_t start=0;bool hasProto=false,serverRole=false;
    while(start<content.size()) {
        auto end=content.find('\n',start);if(end==std::string::npos)end=content.size();auto line=content.substr(start,end-start);start=end+1;
        auto first=line.find_first_not_of(" \t\r");if(first==std::string::npos)continue;line.erase(0,first);auto last=line.find_last_not_of(" \t\r");line.resize(last+1);
        if(!tag.empty()){out+=line+'\n';if(line=="</"+tag+">")tag.clear();continue;}
        if(line[0]=='#'||line[0]==';')continue;
        if(line[0]=='<'){if(line.size()<3||line.back()!='>')throw Error("invalid_profile","Invalid inline block.");tag=line.substr(1,line.size()-2);if(!tags.count(tag))throw Error("invalid_profile","Unsupported inline block.");out+=line+'\n';continue;}
        auto split=line.find_first_of(" \t");auto key=line.substr(0,split);if(key.rfind("--",0)==0)key.erase(0,2);
        // Core understands this compatibility hint. It does not extend our allowlist:
        // every following directive still passes through this same validation.
        if(key!="ignore-unknown-option"&&!allowed.count(key))throw Error("invalid_profile","Unsupported profile directive: "+key);
        auto value=split==std::string::npos?"":line.substr(split+1);value.erase(0,value.find_first_not_of(" \t"));
        if(key=="auth-user-pass"&&!value.empty())throw Error("invalid_profile","External credential files are forbidden.");
        if((key=="dev"&&value!="tun")||(key=="dev-type"&&value!="tun"))throw Error("invalid_profile","Only TUN devices are supported.");
        // Routing is decided exclusively by the profile policy in the coordinator.
        // Keep DHCP/DNS directives so the core can supply DNS defaults.
        if(key=="route"||key=="route-nopull"||key=="redirect-gateway"||key=="redirect-private"||key=="route-ipv6"||key=="ifconfig-ipv6"||key=="block-ipv6"||key=="pull-filter")continue;
        if(key=="remote-cert-tls"){if(value!="server")throw Error("invalid_profile","The remote certificate must have the server role.");serverRole=true;}
        if(key=="remote") {
            std::istringstream words(value);std::string host,port,proto,extra;words>>host>>port>>proto>>extra;
            if(host.empty()||host.find(':')!=std::string::npos||!extra.empty())throw Error("invalid_profile","Use an IPv4 endpoint and standard remote syntax.");
            if(!proto.empty()){if(proto=="udp")proto="udp4";else if(proto=="tcp"||proto=="tcp-client")proto="tcp4-client";else if(proto!="udp4"&&proto!="tcp4"&&proto!="tcp4-client")throw Error("invalid_profile","Unsupported remote transport.");}
            line="remote "+host;if(!port.empty())line+=" "+port;if(!proto.empty())line+=" "+proto;
        }
        if(key=="proto") {hasProto=true;if(value=="udp")value="udp4";else if(value=="tcp"||value=="tcp-client")value="tcp4-client";else if(value!="udp4"&&value!="tcp4"&&value!="tcp4-client")throw Error("invalid_profile","Only IPv4 UDP and TCP clients are supported.");line="proto "+value;}
        out+=line+'\n';
    }
    if(!tag.empty())throw Error("invalid_profile","Unclosed inline block.");
    if(!hasProto)out+="proto udp4\n";
    if(!serverRole)out+="remote-cert-tls server\n";
    // Request IPv4 transport even when the remote hostname has AAAA records.
    out+="\npull-filter ignore route-ipv6\npull-filter ignore ifconfig-ipv6\npull-filter ignore redirect-gateway\n";
    return out;
}
}
