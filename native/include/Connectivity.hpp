#pragma once
#include "Policy.hpp"
#include <chrono>
#include <optional>

namespace vv {
struct PhysicalLink {
    std::string interface,gateway,address;
    bool operator==(const PhysicalLink &b)const{return interface==b.interface&&gateway==b.gateway&&address==b.address;}
};
inline bool physicalIPv4(const std::string &value) {
    try {auto a=ip(value);return a&&(a>>24)!=127&&(a>>16)!=0xa9fe&&a<0xe0000000u;}catch(...){return false;}
}
inline bool usablePhysicalLink(const PhysicalLink &link,bool up) {
    auto &name=link.interface;
    return up&&!name.empty()&&name.rfind("lo",0)!=0&&name.rfind("utun",0)!=0&&name.rfind("tun",0)!=0&&
        name.rfind("tap",0)!=0&&name.rfind("ppp",0)!=0&&name.rfind("ipsec",0)!=0&&
        physicalIPv4(link.address)&&physicalIPv4(link.gateway);
}
inline bool transientNetworkError(const std::string &code) {
    return code=="network_offline"||code=="network_changed";
}
inline bool linkTransitionFailure(const std::string &code) {
    static const std::set<std::string> errors={"network_setup","network_timeout","route_setup","route_inspection","tun_setup","TUN_SETUP_FAILED"};
    return errors.count(code);
}
// Fresh observations, rather than cached NWPath state, are required after wake.
// This class is confined to the helper's network-monitor queue.
class LinkReadiness {
    std::optional<PhysicalLink> candidate;
    std::chrono::steady_clock::time_point since{};
public:
    void reset(){candidate.reset();}
    bool interfaceChanged(const std::string &interface) {
        if(!candidate||candidate->interface!=interface)return false;
        reset();return true;
    }
    bool observe(const std::optional<PhysicalLink> &link,std::chrono::steady_clock::time_point now) {
        if(!link){reset();return false;}
        if(!candidate||!(*candidate==*link)){candidate=link;since=now;return false;}
        return now-since>=std::chrono::seconds(2);
    }
};
// Read only: no interface, route, or resolver mutation.
std::optional<PhysicalLink> physicalLink();
}
