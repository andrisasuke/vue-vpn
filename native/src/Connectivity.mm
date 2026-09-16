#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include "Connectivity.hpp"
#include <ifaddrs.h>
#include <net/if.h>

namespace vv {
std::optional<PhysicalLink> physicalLink(){@autoreleasepool{
    SCDynamicStoreRef store=SCDynamicStoreCreate(nullptr,CFSTR("VueVPN physical link"),nullptr,nullptr);
    if(!store)return std::nullopt;
    NSDictionary *global=CFBridgingRelease(SCDynamicStoreCopyValue(store,CFSTR("State:/Network/Global/IPv4")));
    NSDictionary *setup=CFBridgingRelease(SCDynamicStoreCopyValue(store,CFSTR("Setup:/Network/Global/IPv4")));
    NSDictionary *states=CFBridgingRelease(SCDynamicStoreCopyMultiple(store,nullptr,(__bridge CFArrayRef)@[@"State:/Network/Service/.*/IPv4",@"State:/Network/Interface/.*/Link"]));
    CFRelease(store);
    ifaddrs *addresses=nullptr;if(getifaddrs(&addresses))return std::nullopt;
    std::map<std::string,std::set<std::string>> live;
    for(auto *a=addresses;a;a=a->ifa_next){
        if(!a->ifa_addr||a->ifa_addr->sa_family!=AF_INET||!(a->ifa_flags&IFF_UP)||!(a->ifa_flags&IFF_RUNNING))continue;
        char buffer[INET_ADDRSTRLEN];auto *address=(sockaddr_in*)a->ifa_addr;
        if(inet_ntop(AF_INET,&address->sin_addr,buffer,sizeof(buffer)))live[a->ifa_name].insert(buffer);
    }
    freeifaddrs(addresses);
    NSMutableArray *keys=[NSMutableArray array];
    if([global[@"PrimaryService"] isKindOfClass:NSString.class])
        [keys addObject:[NSString stringWithFormat:@"State:/Network/Service/%@/IPv4",global[@"PrimaryService"]]];
    if([setup[@"ServiceOrder"] isKindOfClass:NSArray.class])for(NSString *service in setup[@"ServiceOrder"])
        [keys addObject:[NSString stringWithFormat:@"State:/Network/Service/%@/IPv4",service]];
    [keys addObjectsFromArray:[[states allKeys] sortedArrayUsingSelector:@selector(compare:)]?:@[]];
    for(NSString *key in keys){
        NSDictionary *state=states[key];if(![state isKindOfClass:NSDictionary.class])continue;
        NSString *iface=state[@"InterfaceName"],*router=state[@"Router"];
        if(![iface isKindOfClass:NSString.class]||![router isKindOfClass:NSString.class]||![state[@"Addresses"] isKindOfClass:NSArray.class])continue;
        // An interface can retain its DHCP address and IFF_RUNNING while Wi-Fi
        // is disassociated. Do not approve that cached IPv4 service as ready.
        NSDictionary *linkState=states[[NSString stringWithFormat:@"State:/Network/Interface/%@/Link",iface]];
        if([linkState isKindOfClass:NSDictionary.class]&&[linkState[@"Active"] isEqual:@NO])continue;
        for(id address in state[@"Addresses"]){
            if(![address isKindOfClass:NSString.class])continue;
            PhysicalLink link{iface.UTF8String,router.UTF8String,[address UTF8String]};
            if(usablePhysicalLink(link,live[link.interface].count(link.address)))return link;
        }
    }
    return std::nullopt;
}}
}
