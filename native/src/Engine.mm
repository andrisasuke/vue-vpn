#import <Foundation/Foundation.h>
#include "Engine.hpp"
#include "Network.hpp"
#include "CoreConfig.hpp"
#include "CoreError.hpp"
#include "Connectivity.hpp"
#include <atomic>
#include <openssl/crypto.h>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <limits>

namespace vv {
static NSString *ns(const std::string &s){return [NSString stringWithUTF8String:s.c_str()];}
static std::string string(id obj,size_t max=1024){if(![obj isKindOfClass:NSString.class]||[obj lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>max)throw Error("invalid_input","Invalid string input.");return [obj UTF8String];}
static std::string identifier(id obj){auto s=string(obj,36);if(![[NSUUID alloc] initWithUUIDString:obj])throw Error("invalid_id","Invalid profile or session identifier.");return s;}
static NSArray *array(id obj,size_t max){if(![obj isKindOfClass:NSArray.class]||[obj count]>max)throw Error("invalid_input","Invalid array input.");return obj;}
static NSDictionary *dictionary(id obj){if(![obj isKindOfClass:NSDictionary.class])throw Error("invalid_input","Invalid object input.");return obj;}
static Policy parsePolicy(NSDictionary *p){
    Policy policy;auto mode=string(p[@"routingMode"],16);if(mode!="all"&&mode!="selected")throw Error("invalid_input","Invalid routing mode.");policy.full=mode=="all";
    for(id obj in array(p[@"routes"],256)){auto r=dictionary(obj);id n=r[@"prefix"];if(![n isKindOfClass:NSNumber.class]||[n intValue]<1||[n intValue]>32||[n doubleValue]!=[n intValue])throw Error("invalid_route","Invalid prefix.");policy.routes.emplace_back(string(r[@"address"],16),[n unsignedIntValue]);}
    auto dns=dictionary(p[@"dns"]);for(id s in array(dns[@"servers"],8))policy.dns.servers.push_back(string(s,16));for(id d in array(dns[@"domains"],32))policy.dns.domains.push_back(string(d,254));validate(policy);return policy;
}
static NSArray *routesJson(const std::vector<Route> &routes){NSMutableArray *a=[NSMutableArray array];for(auto &r:routes)[a addObject:@{@"address":ns(ipString(r.address)),@"prefix":@(r.prefix)}];return a;}
static NSDictionary *dnsJson(const Dns &dns){NSMutableArray *s=[NSMutableArray array],*d=[NSMutableArray array];for(auto &v:dns.servers)[s addObject:ns(v)];for(auto &v:dns.domains)[d addObject:ns(v)];return @{@"servers":s,@"domains":d};}
static uint64_t now(){return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();}
static void wipe(std::string &s){if(!s.empty())OPENSSL_cleanse(s.data(),s.size());s.clear();}
struct Session;
#ifdef VV_ENGINE_TESTING
static openvpn::ClientAPI::Status testConnection(Session &,uint64_t);
#endif
class Client final:public openvpn::ClientAPI::OpenVPNClient {
    Session &session;Network &network;uint64_t generation;Policy desired,effective;Tunnel tunnel;Dns pushed;bool established=false;
    uint64_t lastBytesIn=0,lastBytesOut=0;
    bool failed(const Error &e);
public:
    Client(Session &s,Network &n,Policy p,uint64_t epoch=0):session(s),network(n),generation(epoch),desired(p),effective(p){}
    bool socket_protect(openvpn_io::detail::socket_type fd,std::string remote,bool ipv6)override;
    void event(const openvpn::ClientAPI::Event &e)override;
    void acc_event(const openvpn::ClientAPI::AppCustomControlMessageEvent &)override{}
    void log(const openvpn::ClientAPI::LogInfo &)override{} // Never forward raw core logs: may contain server tokens or profile material.
    void external_pki_cert_request(openvpn::ClientAPI::ExternalPKICertRequest &r)override{r.error=true;r.errorText="External PKI is unsupported.";}
    void external_pki_sign_request(openvpn::ClientAPI::ExternalPKISignRequest &r)override{r.error=true;r.errorText="External PKI is unsupported.";}
    bool pause_on_connection_timeout()override{return false;}
    void clock_tick()override;
    void recordTraffic(const openvpn::ClientAPI::TransportStats &stats);
    void sampleTraffic(){recordTraffic(transport_stats());}
    bool tun_builder_new()override{tunnel={};pushed={};effective=desired;established=false;return true;}
    bool tun_builder_set_layer(int layer)override{return layer==3;}
    bool tun_builder_set_remote_address(const std::string &,bool ipv6)override{return !ipv6;}
    bool tun_builder_add_address(const std::string &a,int prefix,const std::string &gateway,bool ipv6,bool net30)override{if(!ipv6){tunnel.address=a;tunnel.prefix=prefix;tunnel.gateway=gateway;tunnel.net30=net30;}return true;}
    bool tun_builder_reroute_gw(bool,bool,unsigned int)override{return true;}
    bool tun_builder_add_route(const std::string &,int,int,bool)override{return true;}
    bool tun_builder_exclude_route(const std::string &,int,int,bool)override{return true;}
    bool tun_builder_set_mtu(int mtu)override{if(mtu<576||mtu>9000)return false;tunnel.mtu=mtu;return true;}
    bool tun_builder_set_session_name(const std::string &)override{return true;}
    bool tun_builder_set_dns_options(const openvpn::DnsOptions &dns)override{
        for(auto &entry:dns.servers){for(auto &a:entry.second.addresses)if(a.address.find(':')==std::string::npos){if(a.port&&a.port!=53)return false;pushed.servers.push_back(a.address);}for(auto &d:entry.second.domains)pushed.domains.push_back(d.domain);}
        for(auto &d:dns.search_domains)pushed.domains.push_back(d.domain);return true;
    }
    int tun_builder_establish()override;
    bool tun_builder_persist()override{return false;}
    void tun_builder_teardown(bool)override;
};
struct Session {
    Network &network;std::atomic<bool> online{false},canceled{false};std::atomic<uint64_t> generation{0};std::mutex mutex;std::condition_variable wake;
    std::shared_ptr<Client> client;std::thread worker;std::string profileId,id,cleanupId,content,username,password,status="connecting",error,code;
    Policy desired,effective;Tunnel tunnel;uint64_t connectedAt=0,bytesIn=0,bytesOut=0;unsigned attempts=0;bool legacy=false,terminal=false,finished=false;
    Session(Network &n,bool available):network(n),online(available){}
    ~Session(){if(worker.joinable())worker.join();wipe(password);wipe(content);}
    // Predicate changes share the condition-variable mutex: wake/cancel cannot be lost.
    void interrupt(bool cancel){
        {std::lock_guard<std::mutex> lock(mutex);if(cancel){canceled=true;if(!finished)status="disconnecting";}}
        // The core's clock_tick observes cancellation on its own thread. Calling
        // stop from the control queue can contend with an in-progress callback.
        wake.notify_all();
    }
    void environment(bool available){
        {std::lock_guard<std::mutex> lock(mutex);if(online==available)return;online=available;++generation;
            if(!finished&&!canceled){status="reconnecting";attempts=0;}}
        wake.notify_all();
    }
    void setError(const std::string &c,const std::string &message,bool fatal=true){std::lock_guard<std::mutex> lock(mutex);code=c;error=message;terminal=fatal;}
    NSDictionary *snapshot(){std::lock_guard<std::mutex> lock(mutex);return @{@"profileId":ns(profileId),@"sessionId":ns(id),@"status":ns(status),@"address":ns(tunnel.address),@"interface":ns(tunnel.interface),@"connectedAt":connectedAt?(NSObject *)@(connectedAt):(NSObject *)NSNull.null,@"attempts":@(attempts),@"bytesIn":@(bytesIn),@"bytesOut":@(bytesOut),@"error":error.empty()?(NSObject *)NSNull.null:(NSObject *)ns(error),@"errorCode":code.empty()?(NSObject *)NSNull.null:(NSObject *)ns(code),@"effectiveRoutes":routesJson(effective.full?std::vector<Route>{Route("0.0.0.0",0)}:specificRoutes(effective)),@"effectiveDns":dnsJson(effective.dns)};}
    openvpn::ClientAPI::Config config(){return coreConfig(content,legacy);}
    void cleanupNetwork(const std::string &owner) {
        // Route removal/inspection can fail briefly while macOS replaces its
        // Wi-Fi routes. Retry on this worker, never on the XPC control queue.
        for(unsigned attempt=0;;++attempt)try{network.teardown(owner,true);return;}
        catch(const Error &e){if(e.code!="cleanup_failed"||attempt==2)throw;std::this_thread::sleep_for(std::chrono::milliseconds(250*(attempt+1)));}
    }
    void retryCleanup() {
        {std::lock_guard<std::mutex> lock(mutex);if(!finished||code!="cleanup_failed")return;}
        if(worker.joinable())worker.join();
        {std::lock_guard<std::mutex> lock(mutex);finished=false;status="disconnecting";code.clear();error.clear();}
        worker=std::thread([this]{@autoreleasepool{
            try{cleanupNetwork(cleanupId.empty()?id:cleanupId);std::lock_guard<std::mutex> lock(mutex);cleanupId.clear();error.clear();code.clear();}
            catch(const Error &e){setError(e.code,e.what());}
            catch(const std::exception &){setError("cleanup_failed","VPN cleanup could not finish. Retry disconnecting.");}
            std::lock_guard<std::mutex> lock(mutex);status=code.empty()?"disconnected":"error";finished=true;
        }});
    }
    void run() {
        @autoreleasepool {
        bool reserved=false;
        try {
            if(!cleanupId.empty()){cleanupNetwork(cleanupId);cleanupId.clear();}
            network.reserve(id,desired);reserved=true;
            while(!canceled){
                {std::unique_lock<std::mutex> lock(mutex);if(canceled)break;if(!online)status="reconnecting";wake.wait(lock,[&]{return canceled||online.load();});if(canceled)break;terminal=false;error.clear();code.clear();status=attempts?"reconnecting":"connecting";}
                auto epoch=generation.load();
                auto c=std::make_shared<Client>(*this,network,desired,epoch);
                {std::lock_guard<std::mutex> lock(mutex);client=c;}
#ifdef VV_ENGINE_TESTING
                auto result=testConnection(*this,epoch);
#else
                auto cfg=config();auto eval=c->eval_config(cfg);wipe(cfg.content);
                if(eval.error)throw Error("config_error","OpenVPN rejected the profile configuration. Check supported directives and certificates.");
                if(eval.externalPki||eval.privateKeyPasswordRequired||!eval.staticChallenge.empty())throw Error("unsupported_auth","External PKI, encrypted private keys and challenge authentication are not supported.");
                if(!eval.autologin){openvpn::ClientAPI::ProvideCreds creds;creds.username=eval.userlockedUsername.empty()?username:eval.userlockedUsername;creds.password=password;auto provided=c->provide_creds(creds);wipe(creds.password);if(provided.error)throw Error("auth_config","OpenVPN could not accept credentials.");}
                if(canceled)break;
                auto result=c->connect();
#endif
                std::optional<CoreFailure> failure;
                if(result.error)failure=coreFailure(result.status,result.message,content,username,password);
                wipe(result.message);
                c->sampleTraffic();
                {std::lock_guard<std::mutex> lock(mutex);client.reset();}
                c.reset(); // close the transport before releasing its bypass routes
                cleanupNetwork(id);reserved=false;
                if(canceled)break;
                network.reserve(id,desired);reserved=true;
                std::unique_lock<std::mutex> lock(mutex);
                tunnel={};connectedAt=0;
                // Preserve authentication/config/cleanup failures. A network change
                // must not turn a core cancellation into a terminal failure.
                bool changed=epoch!=generation.load();
                if(terminal&&!(changed&&linkTransitionFailure(code)))break;
                bool transient=transientNetworkError(code);
                if(changed||!online||transient){
                    status="reconnecting";error.clear();code.clear();attempts=0;
                    if(online&&!changed)wake.wait_for(lock,std::chrono::seconds(2),[&]{return canceled||!online||epoch!=generation.load();});
                    continue;
                }
                if(failure&&code.empty()){
                    code=failure->code;error=failure->message;
                    if(terminalEvent(code))break;
                }
                auto delay=retryDelay(attempts++);status="reconnecting";
                wake.wait_for(lock,std::chrono::seconds(delay),[&]{return canceled||!online||epoch!=generation.load();});
            }
        }catch(const Error &e){setError(e.code,e.what());}catch(const std::exception &){setError("engine_error","The VPN engine stopped unexpectedly.");}
        std::shared_ptr<Client> last;{std::lock_guard<std::mutex> lock(mutex);last=std::move(client);}
        last.reset();
        if(reserved)try{cleanupNetwork(id);if(code=="cleanup_failed"){std::lock_guard<std::mutex> lock(mutex);error.clear();code.clear();}}
            catch(const Error &e){setError(e.code,e.what());}
        {std::lock_guard<std::mutex> lock(mutex);status=(!error.empty()&&(!canceled||code=="cleanup_failed"))?"error":"disconnected";tunnel={};connectedAt=0;finished=true;wipe(password);wipe(content);}
        }
    }
};
bool Client::failed(const Error &e){session.setError(e.code,e.what(),!transientNetworkError(e.code));return false;}
bool Client::socket_protect(openvpn_io::detail::socket_type fd,std::string remote,bool ipv6){try{if(ipv6)throw Error("ipv6_transport","IPv6 transport is not supported.");return network.protect(session.id,fd,remote);}catch(const Error &e){return failed(e);}}
void Client::recordTraffic(const openvpn::ClientAPI::TransportStats &stats){
    // Core counters are cumulative per Client. Each reconnect uses a fresh
    // Client, but its deltas belong to the same profile session. Read on the
    // engine thread; snapshots only copy cached values under the session mutex.
    std::lock_guard<std::mutex> lock(session.mutex);
    if(session.finished)return;
    auto add=[](long long current,uint64_t &previous,uint64_t &total){
        if(current<=0||static_cast<uint64_t>(current)<=previous)return;
        auto value=static_cast<uint64_t>(current),delta=value-previous;
        total+=std::min(delta,std::numeric_limits<uint64_t>::max()-total);previous=value;
    };
    add(stats.bytesIn,lastBytesIn,session.bytesIn);add(stats.bytesOut,lastBytesOut,session.bytesOut);
}
void Client::clock_tick(){sampleTraffic();if(session.canceled||!session.online||generation!=session.generation.load())stop();}
void Client::event(const openvpn::ClientAPI::Event &e){
    if(e.name=="CONNECTED"){
        if(!established){session.setError("network_setup","OpenVPN connected without a configured IPv4 tunnel.");stop();return;}
        std::lock_guard<std::mutex> lock(session.mutex);if(session.canceled||!session.online||generation!=session.generation.load()){stop();return;}session.status="connected";session.connectedAt=now();session.attempts=0;session.error.clear();session.code.clear();session.effective=effective;session.tunnel=tunnel;
    }else if(e.name=="RECONNECTING"){
        {std::lock_guard<std::mutex> lock(session.mutex);if(!session.canceled)session.status="reconnecting";}stop();
    }else if(e.error||e.fatal||e.name=="AUTH_PENDING"||e.name=="DYNAMIC_CHALLENGE"){
        {std::lock_guard<std::mutex> lock(session.mutex);if(session.code.empty()){session.code=e.name;session.error=e.name=="AUTH_FAILED"?"PIN, password, or username was rejected.":"VPN connection stopped ("+e.name+").";session.terminal=terminalEvent(e.name);}}
        stop();
    }
}
int Client::tun_builder_establish(){try{
    effective=effectivePolicy(desired,pushed);
    int fd=network.establish(session.id,tunnel,effective);established=true;return fd;
}catch(const Error &e){failed(e);return -1;}}
void Client::tun_builder_teardown(bool){
    established=false;
    // The session closes the transport and retries complete cleanup afterward.
    // A temporary partial-cleanup failure must not overwrite an auth error or
    // permanently stop reconnecting after a Wi-Fi transition.
    try{network.teardown(session.id,false);}catch(const Error &){}
}

struct Engine::Impl {Network network;std::atomic<bool> online{false};std::mutex mutex;std::map<std::string,std::shared_ptr<Session>> sessions;};
Engine::Engine():impl(std::make_unique<Impl>()){}
Engine::~Engine(){disconnectAll();}
void Engine::environment(bool available){std::lock_guard<std::mutex> lock(impl->mutex);impl->online=available;for(auto &entry:impl->sessions)entry.second->environment(available);}
void Engine::cancelAll(){std::lock_guard<std::mutex> lock(impl->mutex);for(auto &e:impl->sessions){e.second->interrupt(true);e.second->retryCleanup();}}
void Engine::disconnectAll(){
    std::vector<std::shared_ptr<Session>> sessions;
    {std::lock_guard<std::mutex> lock(impl->mutex);for(auto &e:impl->sessions){e.second->interrupt(true);e.second->retryCleanup();sessions.push_back(e.second);}}
    // Only process shutdown waits for workers, outside the control mutex.
    for(auto &s:sessions)if(s->worker.joinable())s->worker.join();
}
NSDictionary *Engine::request(NSDictionary *request){
    auto op=string(request[@"op"],32);
    if(op=="disconnect_all"){cancelAll();return @{@"ok":@YES};}
    std::lock_guard<std::mutex> lock(impl->mutex);
    if(op=="ping")return @{@"version":@1,@"engine":@"OpenVPN 3 Core 3.11.7",@"online":@(impl->online.load())};
    if(op=="snapshot"){NSMutableArray *s=[NSMutableArray array];for(auto &entry:impl->sessions)[s addObject:entry.second->snapshot()];return @{@"sessions":s,@"online":@(impl->online.load())};}
    auto profileId=identifier(request[@"profileId"]);
    if(op=="disconnect") {auto it=impl->sessions.find(profileId);if(it!=impl->sessions.end()){it->second->interrupt(true);it->second->retryCleanup();}return @{@"ok":@YES};}
    if(op!="connect"&&op!="validate")throw Error("invalid_operation","Unsupported helper operation.");
    auto p=dictionary(request[@"profile"]);auto policy=parsePolicy(p);
    std::string config=safeConfig(string(request[@"content"],8*1024*1024));
    if(op=="validate"){
        Session dummy(impl->network,impl->online.load());Client c(dummy,impl->network,policy);auto cfg=coreConfig(config,[p[@"allowLegacyCipher"] boolValue]);auto eval=c.eval_config(cfg);wipe(config);wipe(cfg.content);
        if(eval.error)throw Error("config_error","OpenVPN rejected the profile. Verify its certificates and directives.");
        if(eval.externalPki||eval.privateKeyPasswordRequired||!eval.staticChallenge.empty())throw Error("unsupported_auth","This profile requires an unsupported authentication method.");
        return @{@"ok":@YES,@"allowPasswordSave":@(eval.allowPasswordSave),@"autologin":@(eval.autologin),@"username":ns(eval.userlockedUsername)};
    }
    std::string cleanupId;
    auto old=impl->sessions.find(profileId);if(old!=impl->sessions.end()){bool finished;{std::lock_guard<std::mutex> guard(old->second->mutex);finished=old->second->finished;if(old->second->code=="cleanup_failed")cleanupId=old->second->cleanupId.empty()?old->second->id:old->second->cleanupId;}if(!finished)throw Error("already_connected","This profile is already active.");}
    if(old==impl->sessions.end()&&impl->sessions.size()>=32)throw Error("limit","At most 32 profiles can have sessions in one app launch.");
    for(auto &entry:impl->sessions)if(entry.first!=profileId){std::lock_guard<std::mutex> guard(entry.second->mutex);if(!entry.second->finished||entry.second->code=="cleanup_failed")checkConflict(policy,entry.second->effective);}
    auto s=std::make_shared<Session>(impl->network,impl->online.load());s->profileId=profileId;s->id=identifier(request[@"sessionId"]);s->cleanupId=std::move(cleanupId);s->desired=policy;s->effective=policy;s->content=std::move(config);s->username=string(request[@"username"],256);s->password=string(request[@"password"],4096);s->legacy=[p[@"allowLegacyCipher"] boolValue];
    for(auto &entry:impl->sessions)if(entry.first!=profileId&&entry.second->id==s->id)throw Error("invalid_id","This session identifier is already in use.");
    // Preserve the old cleanup owner until every part of the new request has
    // been validated. A rejected Connect must not orphan its network state.
    if(old!=impl->sessions.end()){if(old->second->worker.joinable())old->second->worker.join();impl->sessions.erase(old);}
    impl->sessions[profileId]=s;s->worker=std::thread([s]{s->run();});return @{@"ok":@YES};
}
}
