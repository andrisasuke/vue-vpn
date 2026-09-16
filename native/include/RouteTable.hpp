#pragma once
#include "Policy.hpp"
#include <net/route.h>
#include <cstring>
#include <array>

namespace vv {
// NET_RT_DUMP2 enumerates exact entries, unlike `route get`, which can return
// a covering route or an interface-scoped alternative during a Wi-Fi change.
struct KernelRoute {
    uint32_t address=0,mask=0,gateway=0;
    unsigned interface=0;
    int flags=0;
    bool ipv4Gateway=false;
};
inline std::vector<KernelRoute> parseRouteTable(const std::vector<uint8_t> &bytes) {
    auto invalid=[](){throw Error("route_inspection","Cannot read a complete IPv4 route table. Route ownership was retained.");};
    std::vector<KernelRoute> result;
    for(size_t offset=0;offset<bytes.size();) {
        if(bytes.size()-offset<sizeof(rt_msghdr2))invalid();
        rt_msghdr2 header{};std::memcpy(&header,bytes.data()+offset,sizeof(header));
        if(header.rtm_version!=RTM_VERSION||header.rtm_msglen<sizeof(header)||header.rtm_msglen>bytes.size()-offset)invalid();
        std::array<const uint8_t *,RTAX_MAX> addresses{};
        size_t cursor=offset+sizeof(header),end=offset+header.rtm_msglen;
        for(unsigned i=0;i<RTAX_MAX;++i)if(header.rtm_addrs&(1<<i)) {
            if(end-cursor<2)invalid();
            auto length=bytes[cursor];size_t aligned=length?(length+3u)&~3u:4u;
            if(aligned>end-cursor)invalid();
            addresses[i]=bytes.data()+cursor;cursor+=aligned;
        }
        auto dst=addresses[RTAX_DST],mask=addresses[RTAX_NETMASK],gateway=addresses[RTAX_GATEWAY];
        auto ipv4=[&](const uint8_t *a,bool compact){
            if(!a||(!compact&&a[0]<8))invalid();
            uint32_t value=0;
            // Darwin netmasks may have AF_UNSPEC and omit trailing zero bytes.
            if(a[0]>4)std::memcpy(&value,a+4,std::min<size_t>(4,a[0]-4));
            return ntohl(value);
        };
        if(dst&&dst[1]==AF_INET) {
            KernelRoute route;route.address=ipv4(dst,false);route.flags=header.rtm_flags;route.interface=header.rtm_index;
            if(route.flags&RTF_HOST)route.mask=0xffffffffu;
            else {if(!mask)invalid();route.mask=ipv4(mask,true);}
            route.ipv4Gateway=gateway&&gateway[1]==AF_INET;
            if(route.ipv4Gateway)route.gateway=ipv4(gateway,false);
            result.push_back(route);
        }
        offset=end;
    }
    return result;
}
inline bool ownsKernelRoute(const KernelRoute &actual,const Route &route,unsigned interface,const std::string &gateway) {
    // VueVPN installs only unscoped static routes. Never adopt a scoped route,
    // a cloned neighbor entry, or a route through another client's interface.
    return interface&&actual.interface==interface&&(actual.flags&RTF_STATIC)&&!(actual.flags&(RTF_IFSCOPE|RTF_WASCLONED|RTF_LLINFO))&&
        actual.address==route.address&&actual.mask==route.mask()&&
        (gateway.empty()?!(actual.flags&RTF_GATEWAY):
            ((actual.flags&RTF_GATEWAY)&&actual.ipv4Gateway&&actual.gateway==ip(gateway)));
}
}
