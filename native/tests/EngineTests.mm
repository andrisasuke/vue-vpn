// Real Engine/Session lifecycle with an in-memory Network and a fake connection
// driver. No helper process, OpenVPN connect, OS routes, sockets, or UI is used.
#define VV_ENGINE_TESTING 1
#include "../src/Engine.mm"
#include <openvpn/asio/asiostop.hpp>
#include <cassert>
#include <future>
#include <iostream>
using namespace std::chrono_literals;
namespace {
std::mutex fakeMutex;
std::condition_variable fakeWake;
std::map<std::string,unsigned> starts;
std::string blocked,entered,transient,cleanupFailure,authFailure,reserveFailure,temporaryCleanup,transitionFailure;
unsigned cleanups=0,temporaryFailures=0;
bool releaseCleanup=false;
std::string returnedFailure;
openvpn::ClientAPI::Status returnedStatus;
bool preciseFailure=false;
}
namespace vv {
struct Network::Impl {};
Network::Network():impl(std::make_unique<Impl>()){}
Network::~Network()=default;
void Network::reserve(const std::string &id,const Policy &){std::lock_guard<std::mutex> lock(fakeMutex);if(id==reserveFailure)throw Error("route_conflict","Fake reservation conflict");}
bool Network::protect(const std::string &,int,const std::string &){throw Error("network_offline","DHCP is not ready");}
int Network::establish(const std::string &,Tunnel &,Policy &){assert(false);return -1;}
void Network::teardown(const std::string &id,bool){
    std::unique_lock<std::mutex> lock(fakeMutex);
    ++cleanups;
    if(id==blocked){entered=id;fakeWake.notify_all();assert(fakeWake.wait_for(lock,5s,[]{return releaseCleanup;}));}
    if(id==cleanupFailure)throw Error("cleanup_failed","Fake route cleanup failure");
    if(id==temporaryCleanup&&temporaryFailures){--temporaryFailures;throw Error("cleanup_failed","Wi-Fi route replacement in progress");}
}
static openvpn::ClientAPI::Status testConnection(Session &s,uint64_t epoch){
    bool unavailable,auth,transition;
    openvpn::ClientAPI::Status failure;bool precise=false;
    {std::lock_guard<std::mutex> lock(fakeMutex);++starts[s.profileId];auth=authFailure==s.profileId;unavailable=transient==s.profileId;transition=transitionFailure==s.profileId;if(transition)transitionFailure.clear();if(unavailable)transient.clear();
        if(returnedFailure==s.profileId){failure=returnedStatus;returnedFailure.clear();precise=preciseFailure;}
        fakeWake.notify_all();}
    if(failure.error){if(precise)s.setError("route_setup","Unable to add the VPN route.");return failure;}
    if(transition){
        s.setError("TUN_SETUP_FAILED","Interface changed during setup");
        s.environment(false);s.environment(true);return {};
    }
    if(auth){
        Client c(s,s.network,s.desired,epoch);
        openvpn::ClientAPI::Event event;event.name="AUTH_FAILED";event.error=true;c.event(event);
        s.environment(false);s.environment(true);
        return {};
    }
    if(unavailable){
        Client c(s,s.network,s.desired,epoch);
        assert(!c.socket_protect(-1,"192.0.2.1",false));
        openvpn::ClientAPI::Status result;result.error=true;result.status="TUN_SETUP_FAILED";return result;
    }
    // Exercise the real asynchronous stop primitive without a VPN or timers.
    // The previous flag + clock_tick implementation cannot wake this reactor.
    openvpn_io::io_context reactor;
    auto work=openvpn_io::make_work_guard(reactor);
    std::shared_ptr<openvpn::Stop> signal;
    {std::lock_guard<std::mutex> lock(s.mutex);signal=s.cancellation;
        if(!s.canceled&&epoch==s.generation&&s.online)s.status="connected";}
    assert(signal);
    openvpn::AsioStopScope stop(reactor,signal.get(),[&]{reactor.stop();});
    reactor.run_for(4s);
    assert(reactor.stopped());
    return {};
}
}
static NSString *one=@"00000000-0000-4000-8000-000000000001";
static NSString *two=@"00000000-0000-4000-8000-000000000002";
static std::string str(NSString *s){return s.UTF8String;}
static void reset(){std::lock_guard<std::mutex> lock(fakeMutex);starts.clear();blocked.clear();entered.clear();transient.clear();cleanupFailure.clear();authFailure.clear();reserveFailure.clear();temporaryCleanup.clear();transitionFailure.clear();returnedFailure.clear();returnedStatus={};preciseFailure=false;cleanups=temporaryFailures=0;releaseCleanup=false;}
static void connect(vv::Engine &engine,NSString *id,NSString *address,NSString *sessionId=nil){
    engine.request(@{@"op":@"connect",@"profileId":id,@"sessionId":sessionId?:id,@"username":@"test",@"password":@"test-only",@"content":@"client\ndev tun\nremote vpn.example.test\n",@"profile":@{@"routingMode":@"selected",@"routes":@[@{@"address":address,@"prefix":@24}],@"dns":@{@"servers":@[],@"domains":@[]}}});
}
static void started(NSString *id,unsigned count){std::unique_lock<std::mutex> lock(fakeMutex);assert(fakeWake.wait_for(lock,4s,[&]{return starts[str(id)]>=count;}));}
static NSDictionary *session(vv::Engine &engine,NSString *id){for(NSDictionary *s in engine.request(@{@"op":@"snapshot"})[@"sessions"])if([s[@"profileId"] isEqual:id])return s;assert(false);return nil;}
static void finished(vv::Engine &engine,NSString *id,NSString *status=@"disconnected"){
    auto deadline=std::chrono::steady_clock::now()+4s;
    while(![session(engine,id)[@"status"] isEqual:status]){assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(1ms);}
}
static void readiness(){
    vv::PhysicalLink link{"en0","192.168.1.1","192.168.1.20"};vv::LinkReadiness gate;
    auto now=std::chrono::steady_clock::now();
    assert(!gate.observe(link,now));assert(!gate.observe(link,now+1s));assert(gate.observe(link,now+2s));
    for(auto duration:{30min,60min}){
        gate.reset();now+=duration;
        assert(!gate.observe(link,now)); // Same cached link cannot approve wake.
        assert(!gate.observe(std::nullopt,now+1s));
        assert(!gate.observe(link,now+2s));assert(gate.observe(link,now+4s));
    }
    link.gateway="192.168.1.254";assert(!gate.observe(link,now+5s));assert(gate.observe(link,now+7s));
    link.address="192.168.1.21";assert(!gate.observe(link,now+8s));
    assert(gate.observe(link,now+10s));assert(!gate.interfaceChanged("utun8"));
    assert(gate.interfaceChanged("en0")); // A Wi-Fi switch can keep the same DHCP address/router.
    assert(!gate.observe(link,now+11s));assert(gate.observe(link,now+13s));
    assert(vv::usablePhysicalLink(link,true));assert(!vv::usablePhysicalLink(link,false));
    for(auto name:{"utun4","lo0","tun0","tap0","ipsec0"}){link.interface=name;assert(!vv::usablePhysicalLink(link,true));}
    for(auto address:{"0.0.0.0","127.0.0.1","169.254.1.2","224.0.0.1","bad"})assert(!vv::physicalIPv4(address));
}
static void twoSessions(){
    reset();vv::Engine engine;engine.environment(true);
    connect(engine,one,@"10.10.0.0");connect(engine,two,@"10.20.0.0");started(one,1);started(two,1);
    // A fast down/up transition must invalidate both old connection generations.
    engine.environment(false);engine.environment(true);started(one,2);started(two,2);
    engine.environment(false);
    engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    engine.environment(true);started(two,3);
    assert([session(engine,one)[@"status"] isEqual:@"disconnected"]);
    engine.request(@{@"op":@"disconnect_all"});finished(engine,two);
}
static void cancelWithoutClockTick(){
    reset();vv::Engine engine;engine.environment(true);
    connect(engine,one,@"10.10.0.0");connect(engine,two,@"10.20.0.0");
    finished(engine,one,@"connected");finished(engine,two,@"connected");
    engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    // Stopping one reactor must not stop another profile or its routes.
    assert([session(engine,two)[@"status"] isEqual:@"connected"]);
    engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    engine.request(@{@"op":@"disconnect",@"profileId":two});finished(engine,two);
}
static void cancellationBeforeCoreRegisters(){
    reset();vv::Network network;vv::Session session(network,true);
    auto signal=std::make_shared<openvpn::Stop>();session.cancellation=signal;
    session.interrupt(true);session.interrupt(true);
    openvpn_io::io_context reactor;
    auto work=openvpn_io::make_work_guard(reactor);
    unsigned calls=0;
    openvpn::AsioStopScope stop(reactor,signal.get(),[&]{++calls;reactor.stop();});
    reactor.run_for(100ms);assert(reactor.stopped()&&calls==1);
    // A later attempt has a fresh token; previous cancellation cannot leak.
    auto fresh=std::make_shared<openvpn::Stop>();reactor.restart();
    openvpn::AsioStopScope next(reactor,fresh.get(),[&]{++calls;reactor.stop();});
    signal->stop();reactor.poll();assert(calls==1);
    fresh->stop();reactor.run_for(100ms);assert(reactor.stopped()&&calls==2);
}
static void responsiveCleanup(){
    reset();vv::Engine engine;engine.environment(true);
    connect(engine,one,@"10.10.0.0");connect(engine,two,@"10.20.0.0");started(one,1);started(two,1);
    {std::lock_guard<std::mutex> lock(fakeMutex);blocked=str(one);}
    engine.request(@{@"op":@"disconnect",@"profileId":one});
    {std::unique_lock<std::mutex> lock(fakeMutex);assert(fakeWake.wait_for(lock,2s,[]{return !entered.empty();}));}
    auto control=std::async(std::launch::async,[&]{@autoreleasepool{
        assert([session(engine,one)[@"status"] isEqual:@"disconnecting"]);
        engine.environment(false);engine.environment(true);
        engine.request(@{@"op":@"disconnect",@"profileId":two});
        engine.cancelAll();
    }});
    assert(control.wait_for(500ms)==std::future_status::ready);control.get();
    {std::lock_guard<std::mutex> lock(fakeMutex);releaseCleanup=true;fakeWake.notify_all();}
    finished(engine,one);finished(engine,two);
}
static void offlineAndCleanupErrors(){
    reset();{
        vv::Engine engine;connect(engine,one,@"10.10.0.0");engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
        std::lock_guard<std::mutex> lock(fakeMutex);assert(starts.empty());
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);transient=str(one);}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");started(one,2);
        assert([session(engine,one)[@"attempts"] unsignedIntValue]==0);
        {std::lock_guard<std::mutex> lock(fakeMutex);cleanupFailure=str(one);}
        engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"cleanup_failed"]);
        // A new Connect retries the ORIGINAL session's cleanup on its worker.
        connect(engine,one,@"10.10.0.0",two);finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"cleanup_failed"]);
        {std::lock_guard<std::mutex> lock(fakeMutex);assert(starts[str(one)]==2);cleanupFailure.clear();}
        connect(engine,one,@"10.10.0.0");started(one,3);
        engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    }
}
static void cleanupRetryAfterWifiChange(){
    reset();vv::Engine engine;engine.environment(true);
    connect(engine,one,@"10.10.0.0");connect(engine,two,@"10.20.0.0");started(one,1);started(two,1);
    {std::lock_guard<std::mutex> lock(fakeMutex);temporaryCleanup=str(one);temporaryFailures=2;}
    engine.environment(false);engine.environment(true);started(one,2);started(two,2);
    assert(session(engine,one)[@"errorCode"]==NSNull.null);
    {std::lock_guard<std::mutex> lock(fakeMutex);cleanupFailure=str(one);}
    engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one,@"error");
    bool rejected=false;try{connect(engine,one,@"10.20.0.0");}catch(const vv::Error &e){rejected=e.code=="route_conflict";}assert(rejected);
    assert([session(engine,one)[@"errorCode"] isEqual:@"cleanup_failed"]); // Rejected requests keep cleanup ownership.
    {std::lock_guard<std::mutex> lock(fakeMutex);cleanupFailure.clear();}
    engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    assert(session(engine,one)[@"errorCode"]==NSNull.null);
    engine.request(@{@"op":@"disconnect_all"});finished(engine,two);
}
static void terminalErrorsAndReservationOwnership(){
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);transitionFailure=str(one);}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");started(one,2);
        assert(session(engine,one)[@"errorCode"]==NSNull.null);
        engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);authFailure=str(one);}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"AUTH_FAILED"]);
        std::lock_guard<std::mutex> lock(fakeMutex);assert(starts[str(one)]==1);
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);reserveFailure=str(one);}
        vv::Engine engine;connect(engine,one,@"10.10.0.0");finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"route_conflict"]);
        std::lock_guard<std::mutex> lock(fakeMutex);assert(cleanups==0); // Never clean another owner's reservation.
    }
}

static void trafficCounters(){
    reset();vv::Network network;vv::Session first(network,true),second(network,true);
    vv::Client client(first,network,{}),other(second,network,{});
    auto sample=[](vv::Client &c,long long in,long long out){openvpn::ClientAPI::TransportStats stats{};stats.bytesIn=in;stats.bytesOut=out;c.recordTraffic(stats);};
    assert([first.snapshot()[@"bytesIn"] unsignedLongLongValue]==0);
    assert([first.snapshot()[@"bytesOut"] unsignedLongLongValue]==0);
    sample(client,100,100000);sample(client,100,100000); // Repeated snapshots are not extra traffic.
    sample(other,50,500);
    assert([first.snapshot()[@"bytesIn"] unsignedLongLongValue]==100);
    assert([first.snapshot()[@"bytesOut"] unsignedLongLongValue]==100000);
    sample(client,1500000,10000000);
    sample(client,0,-1); // An unavailable core counter must not rewind the total.
    assert([first.snapshot()[@"bytesIn"] unsignedLongLongValue]==1500000);
    assert([first.snapshot()[@"bytesOut"] unsignedLongLongValue]==10000000);
    assert([second.snapshot()[@"bytesIn"] unsignedLongLongValue]==50);
    assert([second.snapshot()[@"bytesOut"] unsignedLongLongValue]==500);
    vv::Client reconnect(first,network,{});sample(reconnect,500,5000000000LL);
    assert([first.snapshot()[@"bytesIn"] unsignedLongLongValue]==1500500);
    assert([first.snapshot()[@"bytesOut"] unsignedLongLongValue]==5010000000ULL);
    vv::Session nextConnection(network,true);
    assert([nextConnection.snapshot()[@"bytesIn"] unsignedLongLongValue]==0);
    assert([nextConnection.snapshot()[@"bytesOut"] unsignedLongLongValue]==0);
}

static void returnedCoreErrors(){
    for(auto label:{"","SSL_ERROR"}){
        reset();{
            {std::lock_guard<std::mutex> lock(fakeMutex);returnedFailure=str(one);returnedStatus.error=true;returnedStatus.status=label;returnedStatus.message="socket bind failed: Address already in use; password=test-only";}
            vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");finished(engine,one,@"error");
            auto snapshot=session(engine,one);
            assert([snapshot[@"errorCode"] isEqual:*label?@"SSL_ERROR":@"OPENVPN_ERROR"]);
            assert([snapshot[@"error"] containsString:@"Address already in use"]);
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
            NSString *json=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
            assert(![json containsString:@"test-only"]&&![json containsString:@"()"]);
            std::lock_guard<std::mutex> lock(fakeMutex);assert(starts[str(one)]==1&&cleanups>0);
        }
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);returnedFailure=str(one);returnedStatus.error=true;}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"OPENVPN_ERROR"]);
        assert([session(engine,one)[@"error"] containsString:@"did not provide an error description"]);
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);returnedFailure=str(one);returnedStatus.error=true;returnedStatus.message="generic wrapper failure";preciseFailure=true;}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");finished(engine,one,@"error");
        assert([session(engine,one)[@"errorCode"] isEqual:@"route_setup"]);
        assert([session(engine,one)[@"error"] isEqual:@"Unable to add the VPN route."]);
    }
    reset();{
        {std::lock_guard<std::mutex> lock(fakeMutex);returnedFailure=str(one);returnedStatus.error=true;returnedStatus.status="TRANSPORT_ERROR";returnedStatus.message="Network is unreachable";}
        vv::Engine engine;engine.environment(true);connect(engine,one,@"10.10.0.0");started(one,2);
        engine.request(@{@"op":@"disconnect",@"profileId":one});finished(engine,one);
    }
}

int main(){@autoreleasepool{readiness();twoSessions();cancelWithoutClockTick();cancellationBeforeCoreRegisters();responsiveCleanup();offlineAndCleanupErrors();cleanupRetryAfterWifiChange();terminalErrorsAndReservationOwnership();trafficCounters();returnedCoreErrors();std::cout<<"Engine lifecycle, asynchronous cancellation, traffic counters, and safe connection diagnostics passed\n";}}
