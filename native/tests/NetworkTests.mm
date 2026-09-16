// Real Network ownership/cleanup logic with all OS boundaries replaced.
// No sockets, routes, SystemConfiguration writes, or runtime files are used.
#define VV_NETWORK_TESTING 1
#include "../src/Network.mm"
#include <cassert>
#include <iostream>
namespace {
std::vector<vv::KernelRoute> table;
std::vector<vv::OwnedRoute> saved;
std::optional<vv::PhysicalLink> fakeLink;
bool inspectFailure=false,deleteFailure=false,deleteNoop=false,addTimeout=false,addFailure=false;
unsigned persistFailures=0,deletes=0;
constexpr auto endpoint="203.0.113.9";
vv::KernelRoute kernel(const vv::OwnedRoute &r,int extra=0) {
    return {r.route.address,r.route.mask(),r.gateway.empty()?0:vv::ip(r.gateway),vv::interfaceIndex(r.interface),
        RTF_UP|RTF_STATIC|(r.route.prefix==32?RTF_HOST:0)|(r.gateway.empty()?0:RTF_GATEWAY)|extra,!r.gateway.empty()};
}
bool has(NSArray *args,NSString *value){return [args containsObject:value];}
vv::CommandResult command(NSString *exe,NSArray *args) {
    assert([exe isEqual:@"/sbin/route"]);
    if(has(args,@"get")) {
        assert(has(args,@"-ifscope")&&has(args,@"default")); // Never best-match ownership lookup.
        return {0,"interface: "+fakeLink->interface+"\ngateway: "+fakeLink->gateway+"\n"};
    }
    assert(has(args,@"-host")); // These cases exercise endpoint ownership.
    vv::OwnedRoute owned{vv::Route(vv::str(args[4]),32),"en0",vv::str(args[5]),true};
    if(has(args,@"add")) {
        if(addFailure)return {1,""};
        table.push_back(kernel(owned));
        if(addTimeout)throw vv::Error("network_timeout","Simulated timeout after route was installed");
    }else {
        assert(has(args,@"delete"));++deletes;
        if(deleteFailure)return {1,""};
        if(!deleteNoop)table.erase(std::remove_if(table.begin(),table.end(),[&](const auto &r){return vv::ownsKernelRoute(r,owned.route,1,owned.gateway);}),table.end());
    }
    return {0,""};
}
void reset() {
    table.clear();saved.clear();vv::testRecovery.clear();
    fakeLink=vv::PhysicalLink{"en0","192.168.1.1","192.168.1.20"};
    inspectFailure=deleteFailure=deleteNoop=addTimeout=addFailure=false;persistFailures=deletes=0;
    vv::testCommand=command;
    vv::testRouteTable=[](){if(inspectFailure)throw vv::Error("route_inspection","Simulated unavailable table");return table;};
    vv::testPersist=[](const auto &journal){if(persistFailures){--persistFailures;throw vv::Error("network_setup","Simulated journal failure");}saved=journal;};
}
template<class F> void throws(const char *code,F fn){bool failed=false;try{fn();}catch(const vv::Error &e){failed=e.code==code;}assert(failed);}
vv::Policy policy(const char *address){vv::Policy p;p.routes.emplace_back(address,24);return p;}
void connect(vv::Network &network,const char *id,const char *address="10.1.0.0"){
    network.reserve(id,policy(address));assert(network.protect(id,-1,endpoint));
}
void wifiChangeAndSharedEndpoint() {
    reset();vv::Network network;connect(network,"one");connect(network,"two","10.2.0.0");
    assert(table.size()==1&&saved.size()==1);
    fakeLink=vv::PhysicalLink{"en0","192.168.2.1","192.168.2.20"};
    // Same session/endpoint must not silently reuse a bypass to the old router.
    throws("network_changed",[&]{network.protect("one",-1,endpoint);});
    network.teardown("one",true);assert(table.size()==1);
    deleteFailure=true;
    throws("cleanup_failed",[&]{network.teardown("two",true);});
    assert(table.size()==1&&saved.size()==1);
    deleteFailure=false;network.teardown("two",true);
    assert(table.empty()&&saved.empty());
    connect(network,"new");assert(table.size()==1&&table[0].gateway==vv::ip("192.168.2.1"));
    network.teardown("new",true);assert(table.empty()&&saved.empty());
}
void inspectionAndDeletionFailures() {
    reset();vv::Network network;connect(network,"one");
    inspectFailure=true;throws("cleanup_failed",[&]{network.teardown("one",true);});
    assert(table.size()==1&&saved.size()==1&&deletes==0);
    inspectFailure=false;deleteNoop=true;
    throws("cleanup_failed",[&]{network.teardown("one",true);});
    assert(table.size()==1&&saved.size()==1); // Exit status zero was not proof of removal.
    deleteNoop=false;persistFailures=1;
    throws("cleanup_failed",[&]{network.teardown("one",true);});
    assert(table.empty()&&saved.size()==1);
    network.teardown("one",true);assert(saved.empty());
}
void mutationTimeoutAndFailedAdd() {
    reset();{
        vv::Network network;network.reserve("one",policy("10.1.0.0"));addTimeout=true;
        throws("network_timeout",[&]{network.protect("one",-1,endpoint);});
        assert(table.size()==1&&saved.size()==1);
        network.teardown("one",true);assert(table.empty()&&saved.empty());
    }
    reset();{
        vv::Network network;network.reserve("one",policy("10.1.0.0"));addFailure=true;
        throws("route_setup",[&]{network.protect("one",-1,endpoint);});
        table.push_back(kernel({vv::Route(endpoint,32),"en0","192.168.1.1",true}));
        network.teardown("one",true);assert(table.size()==1&&deletes==0&&saved.empty());
    }
}
void foreignRoutesAndRemovedBypass() {
    reset();{
        auto own=kernel({vv::Route(endpoint,32),"en0","192.168.1.1",true});
        auto scoped=own;scoped.flags|=RTF_IFSCOPE;table.push_back(scoped);
        auto other=own;other.interface=8;other.gateway=vv::ip("10.8.0.1");table.push_back(other);
        auto covering=kernel({vv::Route("0.0.0.0",0),"en0","192.168.1.1",true});table.push_back(covering);
        vv::Network network;connect(network,"one");assert(table.size()==4);
        network.teardown("one",true);assert(table.size()==3&&saved.empty());
    }
    reset();{
        // A pre-existing identical route is borrowed, never deleted.
        table.push_back(kernel({vv::Route(endpoint,32),"en0","192.168.1.1",true}));
        vv::Network network;connect(network,"one");network.teardown("one",true);
        assert(table.size()==1&&deletes==0&&saved.empty());
    }
    reset();{
        vv::Network network;connect(network,"one");table.clear(); // macOS removed it during DHCP.
        throws("network_changed",[&]{network.protect("one",-1,endpoint);});
        network.teardown("one",true);assert(saved.empty());
    }
}
void startupRecovery() {
    reset();
    vv::OwnedRoute old{vv::Route(endpoint,32),"en0","192.168.1.1",true};
    vv::testRecovery={old};saved={old};table={kernel(old)};inspectFailure=true;
    vv::Network network; // Inspection failure does not make the helper unavailable.
    throws("cleanup_failed",[&]{network.reserve("new",policy("10.1.0.0"));});
    assert(saved.size()==1&&table.size()==1);
    inspectFailure=false;fakeLink->gateway="192.168.2.1";
    connect(network,"new");assert(table.size()==1&&table[0].gateway==vv::ip(fakeLink->gateway));
    network.teardown("new",true);assert(table.empty()&&saved.empty());
}
std::vector<uint8_t> record(const char *destination,const char *mask,unsigned maskLength,int flags=0) {
    rt_msghdr2 h{};h.rtm_version=RTM_VERSION;h.rtm_type=RTM_GET;h.rtm_index=1;
    h.rtm_flags=RTF_UP|RTF_STATIC|RTF_GATEWAY|flags;h.rtm_addrs=RTA_DST|RTA_GATEWAY|RTA_NETMASK;
    std::vector<uint8_t> bytes(sizeof(h));
    auto append=[&](const char *ip,unsigned length,unsigned family){
        sockaddr_in a{};a.sin_len=length;a.sin_family=family;a.sin_addr.s_addr=htonl(vv::ip(ip));
        auto at=bytes.size();bytes.resize(at+(length?(length+3)&~3u:4));
        std::memcpy(bytes.data()+at,&a,length);
    };
    append(destination,16,AF_INET);append("192.168.1.1",16,AF_INET);append(mask,maskLength,AF_UNSPEC);
    h.rtm_msglen=bytes.size();std::memcpy(bytes.data(),&h,sizeof(h));return bytes;
}
void exactRouteParser() {
    for(auto length:{0u,5u,6u,7u,8u}) {
        const char *mask=length==0?"0.0.0.0":length==5?"255.0.0.0":length==6?"255.255.0.0":length==7?"255.255.255.0":"255.255.255.255";
        auto rows=vv::parseRouteTable(record("10.0.0.0",mask,length));
        assert(rows.size()==1&&rows[0].mask==vv::ip(mask)&&rows[0].gateway==vv::ip("192.168.1.1"));
    }
    auto bytes=record(endpoint,"0.0.0.0",0,RTF_HOST);
    auto rows=vv::parseRouteTable(bytes);assert(rows[0].mask==0xffffffffu);
    assert(vv::ownsKernelRoute(rows[0],vv::Route(endpoint,32),1,"192.168.1.1"));
    assert(!vv::ownsKernelRoute(rows[0],vv::Route(endpoint,32),1,"192.168.2.1"));
    for(auto flag:{RTF_IFSCOPE,RTF_WASCLONED,RTF_LLINFO}) {
        auto foreign=rows[0];foreign.flags|=flag;
        assert(!vv::ownsKernelRoute(foreign,vv::Route(endpoint,32),1,"192.168.1.1"));
    }
    for(size_t n=1;n<bytes.size();++n){auto truncated=bytes;truncated.resize(n);throws("route_inspection",[&]{vv::parseRouteTable(truncated);});}
    bytes[sizeof(rt_msghdr2)]=255;throws("route_inspection",[&]{vv::parseRouteTable(bytes);});
}
}
namespace vv {std::optional<PhysicalLink> physicalLink(){return fakeLink;}}
int main(){@autoreleasepool{
    exactRouteParser();wifiChangeAndSharedEndpoint();inspectionAndDeletionFailures();mutationTimeoutAndFailedAdd();foreignRoutesAndRemovedBypass();startupRecovery();
    std::cout<<"Route ownership, Wi-Fi gateway changes, and cleanup recovery tests passed\n";
}}
