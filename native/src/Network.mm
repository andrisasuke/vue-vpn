#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include "Network.hpp"
#include "Connectivity.hpp"
#include "RouteTable.hpp"
#include <sys/socket.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <mutex>
#include <thread>
#include <chrono>
#include <functional>

namespace vv {
static NSString *ns(const std::string &s){return [NSString stringWithUTF8String:s.c_str()];}
static std::string str(NSString *s){return s?s.UTF8String:"";}
struct CommandResult {int status;std::string output;};
struct OwnedRoute {Route route;std::string interface,gateway;bool bypass=false;};
#ifdef VV_NETWORK_TESTING
// Test binaries replace every OS boundary. They never run route/ifconfig,
// open a tunnel, bind a socket, or read/write the helper's real journal.
static std::function<CommandResult(NSString *,NSArray *)> testCommand;
static std::function<std::vector<KernelRoute>()> testRouteTable;
static std::function<void(const std::vector<OwnedRoute> &)> testPersist;
static std::vector<OwnedRoute> testRecovery;
#endif
// Only fixed system executables with validated, separate argv entries. No shell.
static CommandResult command(NSString *exe,NSArray<NSString *> *args) {
#ifdef VV_NETWORK_TESTING
    return testCommand(exe,args);
#else
    @autoreleasepool {
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:exe];task.arguments=args;
        task.environment=@{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin",@"LC_ALL":@"C"};
        NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=[NSFileHandle fileHandleWithNullDevice];
        NSError *error=nil;if(![task launchAndReturnError:&error])throw Error("network_setup","Unable to execute a macOS networking operation.");
        for(int n=0;n<250&&task.running;n++)std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if(task.running){kill(task.processIdentifier,SIGKILL);[task waitUntilExit];throw Error("network_timeout","A macOS networking operation timed out.");}
        [task waitUntilExit];NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];
        return {task.terminationStatus,str([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding])};
    }
#endif
}
static std::map<std::string,std::string> fields(const std::string &s) {
    std::map<std::string,std::string> result;size_t start=0;
    while(start<s.size()){auto end=s.find('\n',start);if(end==std::string::npos)end=s.size();auto line=s.substr(start,end-start);start=end+1;auto colon=line.find(':');if(colon==std::string::npos)continue;
        auto trim=[](std::string s){auto a=s.find_first_not_of(" \t\r");if(a==std::string::npos)return std::string{};return s.substr(a,s.find_last_not_of(" \t\r")-a+1);};result[trim(line.substr(0,colon))]=trim(line.substr(colon+1));}
    return result;
}
static unsigned interfaceIndex(const std::string &name) {
#ifdef VV_NETWORK_TESTING
    return name=="en0"?1:name=="en1"?2:name=="utun8"?8:0;
#else
    return if_nametoindex(name.c_str());
#endif
}
static std::vector<KernelRoute> routeTable() {
#ifdef VV_NETWORK_TESTING
    return testRouteTable();
#else
    int mib[]={CTL_NET,PF_ROUTE,0,AF_INET,NET_RT_DUMP2,0};
    for(unsigned attempt=0;attempt<3;++attempt) {
        size_t size=0;
        if(sysctl(mib,6,nullptr,&size,nullptr,0)||size>32*1024*1024)break;
        std::vector<uint8_t> bytes(size+size/2+4096);size=bytes.size();
        if(!sysctl(mib,6,bytes.data(),&size,nullptr,0)){bytes.resize(size);return parseRouteTable(bytes);}
        if(errno!=ENOMEM)break; // The table can grow between the two calls.
    }
    throw Error("route_inspection","Cannot inspect IPv4 routes. Route ownership was retained for cleanup.");
#endif
}
static bool matches(const OwnedRoute &r) {
    auto table=routeTable();auto index=interfaceIndex(r.interface);
    return std::any_of(table.begin(),table.end(),[&](const auto &entry){return ownsKernelRoute(entry,r.route,index,r.gateway);});
}
static NSArray *routeArgs(NSString *verb,const OwnedRoute &r) {
    NSMutableArray *a=[NSMutableArray arrayWithArray:@[@"-n",verb,@"-inet",r.route.prefix==32?@"-host":@"-net",ns(ipString(r.route.address))]];
    if(r.route.prefix!=32)[a addObjectsFromArray:@[@"-netmask",ns(ipString(r.route.mask()))]];
    if(r.gateway.empty())[a addObjectsFromArray:@[@"-interface",ns(r.interface)]];else[a addObject:ns(r.gateway)];return a;
}
struct Network::Impl {
    std::mutex mutex;
    struct Entry {Policy policy;std::vector<OwnedRoute> routes;std::set<std::string> endpoints;std::string dnsKey;};
    struct Bypass {OwnedRoute route;unsigned refs=0;bool owned=false;};
    std::map<std::string,Entry> entries;
    std::map<std::string,Bypass> bypasses;
    std::vector<OwnedRoute> journal;
    SCDynamicStoreRef store=nullptr;
    const char *directory="/var/run/com.vuevpn.helper";
    std::string journalPath="/var/run/com.vuevpn.helper/routes.json";
    Impl() {
#ifdef VV_NETWORK_TESTING
        journal=testRecovery;recoverRoutes();
#else
        struct stat st{};
        if(mkdir(directory,0700)<0&&errno!=EEXIST)throw Error("network_setup","Cannot create helper runtime directory.");
        if(lstat(directory,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=0||(st.st_mode&077)!=0)throw Error("network_setup","Unsafe helper runtime directory.");
        NSDictionary *options=@{(__bridge NSString *)kSCDynamicStoreUseSessionKeys:@YES};
        store=SCDynamicStoreCreateWithOptions(nullptr,CFSTR("VueVPN"),(__bridge CFDictionaryRef)options,nullptr,nullptr);
        if(!store)throw Error("dns_setup","Cannot open SystemConfiguration session.");
        try{recover();}catch(...){CFRelease(store);store=nullptr;throw;}
#endif
    }
    ~Impl(){if(store)CFRelease(store);}
    void persist() {
#ifdef VV_NETWORK_TESTING
        testPersist(journal);
#else
        NSMutableArray *items=[NSMutableArray array];for(auto &r:journal)[items addObject:@{@"address":ns(ipString(r.route.address)),@"prefix":@(r.route.prefix),@"interface":ns(r.interface),@"gateway":ns(r.gateway),@"bypass":@(r.bypass)}];
        NSData *data=[NSJSONSerialization dataWithJSONObject:items options:0 error:nil];auto temporary=journalPath+".tmp";
        int fd=open(temporary.c_str(),O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)throw Error("network_setup","Cannot write route ownership journal.");
        const char *p=(const char*)data.bytes;size_t left=data.length;bool ok=true;
        while(left){auto n=write(fd,p,left);if(n<=0){ok=false;break;}p+=n;left-=n;}
        if(fsync(fd))ok=false;close(fd);if(!ok||rename(temporary.c_str(),journalPath.c_str()))throw Error("network_setup","Cannot persist route ownership journal.");
#endif
    }
    void recover() {
        int fd=open(journalPath.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0){if(errno==ENOENT)return;throw Error("network_setup","Cannot read route ownership journal.");}
        struct stat st{};if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_size>1024*1024){close(fd);throw Error("network_setup","Invalid route ownership journal.");}
        NSMutableData *data=[NSMutableData dataWithLength:st.st_size];auto n=read(fd,data.mutableBytes,data.length);close(fd);if(n!=(ssize_t)data.length)throw Error("network_setup","Incomplete route journal.");
        id items=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![items isKindOfClass:[NSArray class]])throw Error("network_setup","Invalid route journal data.");
        for(NSDictionary *item in items){OwnedRoute r{Route(str(item[@"address"]),[item[@"prefix"] unsignedIntValue]),str(item[@"interface"]),str(item[@"gateway"]),[item[@"bypass"] boolValue]};
            if(!r.gateway.empty())ip(r.gateway);
            if(r.interface.empty()||r.interface.size()>IFNAMSIZ||!std::all_of(r.interface.begin(),r.interface.end(),[](unsigned char c){return std::isalnum(c);}))throw Error("network_setup","Invalid journal interface.");
            journal.push_back(r);
        }
        recoverRoutes();
    }
    void recoverRoutes() {
        // A transient inspection/deletion failure must not kill the helper or
        // discard later journal entries. Retry remaining ownership on connect.
        auto pending=journal;for(const auto &r:pending)try{remove(r);}catch(const Error &){}
    }
    bool journaled(const OwnedRoute &r)const {
        return std::any_of(journal.begin(),journal.end(),[&](const auto &j){return j.route==r.route&&j.interface==r.interface&&j.gateway==r.gateway;});
    }
    void add(const OwnedRoute &r) {
        // Reserve ownership before mutation. A failed add must never acquire an existing route.
        if(matches(r))throw Error("route_exists","A requested route already exists outside VueVPN.");
        journal.push_back(r);try{persist();}catch(...){journal.pop_back();throw;}
        if(command(@"/sbin/route",routeArgs(@"add",r)).status){journal.pop_back();persist();throw Error("route_setup","Unable to add VPN route "+r.route.cidr()+". It may already be owned by another network.");}
    }
    bool remove(const OwnedRoute &r) {
        if(matches(r)) {
            // A delete can report failure after macOS removed the route itself.
            // Conversely, success alone is not evidence that cleanup finished.
            command(@"/sbin/route",routeArgs(@"delete",r));
            if(matches(r))return false;
        }
        auto previous=journal;
        journal.erase(std::remove_if(journal.begin(),journal.end(),[&](const auto &j){return j.route==r.route&&j.interface==r.interface&&j.gateway==r.gateway;}),journal.end());
        try{persist();}catch(...){journal=std::move(previous);throw;}return true;
    }
    std::pair<std::string,std::string> physical() {
        auto link=physicalLink();
        if(!link)throw Error("network_offline","Waiting for the physical IPv4 network to reconnect.");
        auto iface=link->interface,gateway=link->gateway;
        // Get the scoped physical gateway even when a different VPN owns the unscoped default.
        auto r=command(@"/sbin/route",@[@"-n",@"get",@"-inet",@"-ifscope",ns(iface),@"default"]);
        if(!r.status){auto f=fields(r.output);if(f["interface"]==iface)gateway=f["gateway"];}
        if(!physicalIPv4(gateway))throw Error("network_offline","Waiting for an IPv4 gateway.");return {iface,gateway};
    }
    void clean(const std::string &id,bool release) {
        auto found=entries.find(id);if(found==entries.end())return;auto &e=found->second;bool ok=true;
        if(!e.dnsKey.empty()){CFPropertyListRef existing=SCDynamicStoreCopyValue(store,(__bridge CFStringRef)ns(e.dnsKey));if(existing){CFRelease(existing);if(!SCDynamicStoreRemoveValue(store,(__bridge CFStringRef)ns(e.dnsKey)))ok=false;}if(ok)e.dnsKey.clear();}
        std::vector<OwnedRoute> remaining;
        for(auto r=e.routes.rbegin();r!=e.routes.rend();++r){
            bool removed=false;try{removed=remove(*r);}catch(const Error &){}
            if(!removed){remaining.push_back(*r);ok=false;}
        }
        std::reverse(remaining.begin(),remaining.end());e.routes=remaining;
        // Transport bypasses are retained until the engine socket is closed.
        if(release){
            std::set<std::string> retained;
            for(auto &endpoint:e.endpoints){
                auto b=bypasses.find(endpoint);if(b==bypasses.end())continue;
                if(b->second.refs>1){--b->second.refs;continue;}
                bool removed=!b->second.owned;
                if(!removed)try{removed=remove(b->second.route);}catch(const Error &){}
                // Keep the final reference and ownership record on failure so a
                // later cleanup cannot silently forget an installed bypass.
                if(removed)bypasses.erase(b);else{retained.insert(endpoint);ok=false;}
            }
            e.endpoints=std::move(retained);if(ok)entries.erase(found);
        }
        if(!ok)throw Error("cleanup_failed","Some VPN network settings could not be removed yet. Retry Connect or Disconnect to resume cleanup.");
    }
};
Network::Network():impl(std::make_unique<Impl>()){}
Network::~Network(){std::lock_guard<std::mutex> lock(impl->mutex);std::vector<std::string> ids;for(auto &e:impl->entries)ids.push_back(e.first);for(auto &id:ids)try{impl->clean(id,true);}catch(...){} }
void Network::reserve(const std::string &id,const Policy &policy){std::lock_guard<std::mutex> lock(impl->mutex);
    if(impl->entries.empty()&&!impl->journal.empty()){impl->recoverRoutes();if(!impl->journal.empty())throw Error("cleanup_failed","Previous VPN routes are still being cleaned up. Retry the connection.");}
    if(impl->entries.count(id))throw Error("already_connected","This session already exists.");for(auto &other:impl->entries)checkConflict(policy,other.second.policy);impl->entries[id].policy=policy;}
bool Network::protect(const std::string &id,int socket,const std::string &endpoint) {
    std::lock_guard<std::mutex> lock(impl->mutex);ip(endpoint);auto &e=impl->entries.at(id);auto [iface,gateway]=impl->physical();
    unsigned index=interfaceIndex(iface);
#ifndef VV_NETWORK_TESTING
    if(!index||setsockopt(socket,IPPROTO_IP,IP_BOUND_IF,&index,sizeof(index)))throw Error("network_offline","Waiting for the physical IPv4 interface.");
#endif
    auto &b=impl->bypasses[endpoint];
    if(b.refs&&(b.route.interface!=iface||b.route.gateway!=gateway))throw Error("network_changed","Waiting for old VPN transports to release the previous gateway.");
    if(b.refs&&!matches(b.route))throw Error("network_changed","The VPN server route changed. Waiting for transport cleanup.");
    if(e.endpoints.count(endpoint))return true;
    if(b.refs==0){
        b.route={Route(endpoint,32),iface,gateway,true};b.owned=false;
        bool existing=matches(b.route);
        // Track the owning session BEFORE mutation: a command timeout may mean
        // the route was installed even though no successful reply was received.
        ++b.refs;e.endpoints.insert(endpoint);
        if(!existing){try{impl->add(b.route);b.owned=true;}catch(...){b.owned=impl->journaled(b.route);throw;}}
    }else{++b.refs;e.endpoints.insert(endpoint);}
    return true;
}
int Network::establish(const std::string &id,Tunnel &t,Policy &effective) {
#ifdef VV_NETWORK_TESTING
    throw Error("test_boundary","Unit tests must not create a real tunnel.");
#else
    std::lock_guard<std::mutex> lock(impl->mutex);validate(effective);auto &entry=impl->entries.at(id);
    if(!effective.full&&!effective.dns.servers.empty()&&effective.dns.domains.empty())throw Error("dns_domain_required","Set internal DNS domains for this split profile, or remove its DNS servers.");
    for(auto &other:impl->entries)if(other.first!=id)checkConflict(effective,other.second.policy);
    ip(t.address);if(!t.gateway.empty())ip(t.gateway);if(t.prefix>32||t.mtu<576||t.mtu>9000)throw Error("tun_setup","Invalid tunnel parameters.");
    int fd=socket(PF_SYSTEM,SOCK_DGRAM,SYSPROTO_CONTROL);if(fd<0)throw Error("tun_setup","Cannot create utun socket.");
    try {
        fcntl(fd,F_SETFD,FD_CLOEXEC);ctl_info info{};strlcpy(info.ctl_name,UTUN_CONTROL_NAME,sizeof(info.ctl_name));
        if(ioctl(fd,CTLIOCGINFO,&info))throw Error("tun_setup","Cannot find the macOS utun controller.");
        sockaddr_ctl address{};address.sc_len=sizeof(address);address.sc_family=AF_SYSTEM;address.ss_sysaddr=AF_SYS_CONTROL;address.sc_id=info.ctl_id;address.sc_unit=0;
        if(connect(fd,(sockaddr*)&address,sizeof(address)))throw Error("tun_setup","Cannot establish utun device.");
        char name[IFNAMSIZ]{};socklen_t len=sizeof(name);if(getsockopt(fd,SYSPROTO_CONTROL,UTUN_OPT_IFNAME,name,&len))throw Error("tun_setup","Cannot read utun interface name.");t.interface=name;
        auto peer=!t.gateway.empty()?t.gateway:t.address;
        // A point-to-point /32 avoids an implicit route to the entire assigned VPN subnet.
        std::string mask="255.255.255.255";
        if(command(@"/sbin/ifconfig",@[ns(t.interface),@"inet",ns(t.address),ns(peer),@"netmask",ns(mask),@"mtu",ns(std::to_string(t.mtu)),@"up"]).status)throw Error("tun_setup","Cannot configure the VPN IPv4 interface.");
        auto routes=effective.full?std::vector<Route>{Route("0.0.0.0",1),Route("128.0.0.0",1)}:effective.routes;
        for(auto &s:effective.dns.servers){Route host(s,32);if(!std::any_of(routes.begin(),routes.end(),[&](auto &r){return r.overlaps(host);}))routes.push_back(host);}
        for(auto &r:routes){OwnedRoute owned{r,t.interface,"",false};entry.routes.push_back(owned);
            try{impl->add(owned);}catch(...){if(!impl->journaled(owned))entry.routes.pop_back();throw;}}
        if(!effective.dns.servers.empty()) {
            entry.dnsKey="State:/Network/Service/com.vuevpn."+id+"/DNS";
            NSMutableArray *servers=[NSMutableArray array],*domains=[NSMutableArray array];for(auto &s:effective.dns.servers)[servers addObject:ns(s)];for(auto &d:effective.dns.domains)[domains addObject:ns(d)];
            if(effective.full)[domains addObject:@""];
            NSMutableArray *orders=[NSMutableArray array];for(NSUInteger i=0;i<domains.count;++i)[orders addObject:@10000];
            NSDictionary *dns=@{@"ServerAddresses":servers,@"SupplementalMatchDomains":domains,@"SupplementalMatchOrders":orders,@"SupplementalMatchDomainsNoSearch":@YES,@"InterfaceName":ns(t.interface),@"SearchOrder":@10000};
            if(!SCDynamicStoreSetValue(impl->store,(__bridge CFStringRef)ns(entry.dnsKey),(__bridge CFDictionaryRef)dns))throw Error("dns_setup","Cannot install the VPN DNS resolver.");
        }
        entry.policy=effective;return fd;
    }catch(...){auto error=std::current_exception();try{impl->clean(id,false);}catch(...){}close(fd);std::rethrow_exception(error);}
#endif
}
void Network::teardown(const std::string &id,bool release){std::lock_guard<std::mutex> lock(impl->mutex);impl->clean(id,release);}
}
